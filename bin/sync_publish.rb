#!/usr/bin/env ruby
# frozen_string_literal: true
#
# 옵시디언 볼트 전체를 스캔해서 다음을 자동화합니다.
#   1. frontmatter 에 `publish: true` 가 있는 노트를 publish/_notes/ 로 동기화
#   2. 그 노트들이 참조하는 이미지를 publish/assets/ 로 복사
#   3. 옵시디언 위키링크 임베드(![[...]]) 와 표준 마크다운 이미지 문법을
#      모두 표준 형태(![alt](/assets/<basename>)) 로 변환
#   4. 더 이상 참조되지 않는 자동 관리 이미지는 자동 삭제
#
# 사용법:
#   ruby bin/sync_publish.rb              # 실제 동기화
#   ruby bin/sync_publish.rb --dry-run    # 변경 없이 미리보기만
#   ruby bin/sync_publish.rb --quiet      # 로그 줄이기
#
# 자동 관리 vs 직접 관리:
#   - 노트:   frontmatter `_synced_from` 키가 있으면 자동 관리 (매 실행마다 재생성)
#   - 이미지: publish/.synced_assets.json 매니페스트에 등록된 것만 자동 관리
#   둘 다 매니페스트/마커 없이 직접 만든 파일은 절대 건드리지 않음.

require "yaml"
require "date"
require "json"
require "cgi"
require "fileutils"
require "pathname"
require "optparse"

ROOT            = Pathname.new(File.expand_path("../..", __dir__))
PUBLISH_DIR     = ROOT.join("publish")
NOTES_DIR       = PUBLISH_DIR.join("_notes")
ASSETS_DIR      = PUBLISH_DIR.join("assets")
ASSETS_MANIFEST = PUBLISH_DIR.join(".synced_assets.json")

# 노트 스캔 시 무시할 디렉터리 (publish 폴더 안의 .md 는 자동 관리 대상이 아님)
NOTE_EXCLUDED_DIRS  = %w[publish .obsidian .trash .git node_modules vendor _site .bundle].freeze
# 이미지 스캔 시 무시할 디렉터리 (publish 폴더 안 assets 는 포함되어야 함)
IMAGE_EXCLUDED_DIRS = %w[.obsidian .trash .git node_modules _site .bundle].freeze
IMAGE_EXTS          = %w[.png .jpg .jpeg .gif .webp .svg .bmp].freeze
MARKER              = "_synced_from"

WIKILINK_EMBED = /!\[\[([^\]|]+?)(?:\|([^\]]+))?\]\]/.freeze
MARKDOWN_IMG   = /!\[([^\]]*)\]\(\s*([^)\s]+)(?:\s+"[^"]*")?\s*\)/.freeze

options = { dry_run: false, verbose: true }
OptionParser.new do |opts|
  opts.banner = "Usage: ruby bin/sync_publish.rb [options]"
  opts.on("--dry-run", "변경 없이 미리보기") { options[:dry_run] = true }
  opts.on("-q", "--quiet", "로그 최소화")    { options[:verbose] = false }
  opts.on("-h", "--help", "도움말") { puts opts; exit }
end.parse!

# ===============================================================
# 헬퍼
# ===============================================================
def parse_frontmatter(content)
  return [nil, content] unless content.start_with?("---")
  parts = content.split(/^---\s*$/m, 3)
  return [nil, content] if parts.size < 3
  begin
    fm = YAML.safe_load(parts[1], permitted_classes: [Date, Time, Symbol], aliases: true)
    body = parts[2].sub(/\A\r?\n/, "")
    [fm, body]
  rescue Psych::SyntaxError => e
    warn "⚠️  YAML 파싱 실패 — #{e.message}"
    [nil, content]
  end
end

def slugify(text)
  text.to_s.strip.downcase
      .gsub(/\s+/, "-")
      .gsub(/[^\p{L}\p{N}\-_\/]/u, "")
      .gsub(/-+/, "-")
      .gsub(/^-|-$/, "")
end

def excluded?(path, dirs)
  rel = path.to_s
  dirs.any? do |d|
    rel.include?("/#{d}/") || rel.start_with?("#{ROOT}/#{d}/")
  end
end

def image_extension?(reference)
  ext_target = reference.split(/[?#]/).first.to_s
  IMAGE_EXTS.include?(File.extname(ext_target).downcase)
end

def in_publish_assets?(path)
  path.cleanpath.to_s.start_with?(ASSETS_DIR.cleanpath.to_s + File::SEPARATOR)
end

# 볼트 안의 이미지 파일을 basename(소문자) → [Pathname,...] 인덱스로 만든다.
def build_image_index
  index = Hash.new { |h, k| h[k] = [] }
  Pathname.glob(ROOT.join("**/*")) do |path|
    next unless path.file?
    next if excluded?(path, IMAGE_EXCLUDED_DIRS)
    next unless IMAGE_EXTS.include?(path.extname.downcase)
    index[path.basename.to_s.downcase] << path
  end
  index
end

# 이미지 참조 문자열 → 실제 파일 Pathname (없으면 nil)
def find_image(reference, image_index, note_path)
  return nil if reference.match?(/\A(https?:|data:)/)
  return nil if reference.start_with?("/assets/")  # 이미 정상 위치

  decoded = CGI.unescape(reference)

  # 1. 상대 경로 — 노트 파일 위치 기준 (옵시디언이 자동 생성하는 markdown 의 일반 케이스)
  if decoded.include?("/")
    candidate = note_path.dirname.join(decoded).expand_path
    return candidate if candidate.file?
  end

  # 2. basename 기준 인덱스 검색 (위키링크 ![[image.png]] 또는 옵시디언이 만든 짧은 경로)
  basename = File.basename(decoded.split(/[?#]/).first).downcase
  matches = image_index[basename] || []
  return nil if matches.empty?

  if matches.size > 1
    warn "⚠️  이미지 '#{basename}' 가 여러 곳에서 발견됨, 첫 번째 사용:"
    matches.each_with_index { |p, i| warn "    [#{i + 1}] #{p.relative_path_from(ROOT)}" }
  end
  matches.first
end

# 본문에서 이미지 참조를 찾아 표준 마크다운 + /assets/ 경로로 치환.
# used_assets 에 발견된 Pathname 들을 누적.
def rewrite_image_refs(body, note_path, image_index, used_assets, missing_refs)
  result = body.dup

  # 위키링크 임베드: ![[file]] 또는 ![[file|alt]]
  result = result.gsub(WIKILINK_EMBED) do
    full   = Regexp.last_match(0)
    target = Regexp.last_match(1).to_s.strip
    alt    = Regexp.last_match(2)&.strip || ""

    next full unless image_extension?(target)

    src = find_image(target, image_index, note_path)
    if src
      used_assets << src
      "![#{alt}](/assets/#{File.basename(src)})"
    else
      missing_refs << { ref: target, note: note_path }
      full
    end
  end

  # 표준 마크다운: ![alt](path "title")
  result = result.gsub(MARKDOWN_IMG) do
    full = Regexp.last_match(0)
    alt  = Regexp.last_match(1).to_s
    path = Regexp.last_match(2).to_s.strip

    next full unless image_extension?(path)
    next full if path.match?(/\A(https?:|data:)/)
    next full if path.start_with?("/assets/")

    src = find_image(path, image_index, note_path)
    if src
      used_assets << src
      "![#{alt}](/assets/#{File.basename(src)})"
    else
      missing_refs << { ref: path, note: note_path }
      full
    end
  end

  result
end

# ===============================================================
# 1. 발행 대상 노트 수집
# ===============================================================
publishable = []
Pathname.glob(ROOT.join("**/*.md")) do |path|
  next if excluded?(path, NOTE_EXCLUDED_DIRS)
  next unless path.file?

  fm, body = parse_frontmatter(path.read)
  next unless fm.is_a?(Hash) && fm["publish"] == true

  publishable << { path: path, frontmatter: fm, body: body }
end

# ===============================================================
# 2. 슬러그 결정 + 충돌 검사
# ===============================================================
publishable.each do |item|
  fm = item[:frontmatter]
  slug =
    if fm["permalink"]
      fm["permalink"].to_s.sub(%r{^/}, "").sub(%r{/$}, "")
    elsif fm["slug"]
      fm["slug"].to_s
    else
      slugify(item[:path].basename(".md").to_s)
    end
  slug = "untitled-#{Time.now.to_i}" if slug.empty?
  item[:slug] = slug
end

slug_map = publishable.group_by { |i| i[:slug] }
slug_map.each do |slug, items|
  next if items.size <= 1
  warn "⚠️  slug '#{slug}' 가 #{items.size}개 파일에 중복됩니다:"
  items.each { |i| warn "    - #{i[:path].relative_path_from(ROOT)}" }
  warn "    `permalink:` 또는 파일명을 다르게 지정해 주세요. 첫 번째 파일만 동기화합니다."
end
publishable = slug_map.values.map(&:first)

# ===============================================================
# 3. 직접 만든 노트와의 충돌 방지
# ===============================================================
manual_slugs = []
NOTES_DIR.glob("**/*.md") do |path|
  fm, _ = parse_frontmatter(path.read)
  next if fm.is_a?(Hash) && fm[MARKER]
  manual_slugs << path.relative_path_from(NOTES_DIR).to_s.sub(/\.md$/, "")
end

publishable.reject! do |item|
  if manual_slugs.include?(item[:slug])
    warn "⚠️  '#{item[:slug]}' 는 이미 직접 작성된 _notes/ 파일과 동일한 슬러그입니다."
    warn "    원본: #{item[:path].relative_path_from(ROOT)}"
    warn "    -> 직접 만든 파일을 보호하기 위해 동기화에서 제외합니다."
    true
  else
    false
  end
end

# ===============================================================
# 4. 이미지 인덱스 + 본문 변환
# ===============================================================
image_index   = build_image_index
used_assets   = []
missing_refs  = []

publishable.each do |item|
  item[:body] = rewrite_image_refs(item[:body], item[:path], image_index, used_assets, missing_refs)
end

missing_refs.each do |m|
  warn "⚠️  이미지 미발견: #{m[:ref]}  (in #{m[:note].relative_path_from(ROOT)})"
end

# ===============================================================
# 5. 이전 동기화 노트 정리
# ===============================================================
old_synced = []
NOTES_DIR.glob("**/*.md") do |path|
  fm, _ = parse_frontmatter(path.read)
  old_synced << path if fm.is_a?(Hash) && fm[MARKER]
end

removed_notes = 0
old_synced.each do |path|
  rel = path.relative_path_from(NOTES_DIR)
  if options[:dry_run]
    puts "would remove note: _notes/#{rel}"
  else
    path.delete
    puts "removed: _notes/#{rel}" if options[:verbose]
  end
  removed_notes += 1
end

# ===============================================================
# 6. 새 노트 작성
# ===============================================================
FileUtils.mkdir_p(NOTES_DIR) unless options[:dry_run]
added_notes = 0
publishable.each do |item|
  fm = item[:frontmatter].dup
  fm.delete("publish")
  fm[MARKER] = item[:path].relative_path_from(ROOT).to_s

  out_path = NOTES_DIR.join("#{item[:slug]}.md")
  yaml_str = fm.to_yaml.sub(/^---\n/, "").sub(/\n\Z/, "\n")
  payload  = "---\n#{yaml_str}---\n\n#{item[:body]}"

  if options[:dry_run]
    puts "would write: _notes/#{item[:slug]}.md  (from #{item[:path].relative_path_from(ROOT)})"
  else
    out_path.parent.mkpath
    out_path.write(payload)
    File.utime(item[:path].atime, item[:path].mtime, out_path)
    puts "synced: #{item[:path].relative_path_from(ROOT)} -> _notes/#{item[:slug]}.md" if options[:verbose]
  end
  added_notes += 1
end

# ===============================================================
# 7. 이미지 매니페스트 처리
# ===============================================================
old_manifest = {}
if ASSETS_MANIFEST.exist?
  begin
    old_manifest = JSON.parse(ASSETS_MANIFEST.read)
  rescue JSON::ParserError
    warn "⚠️  매니페스트 파싱 실패, 빈 상태로 시작"
  end
end

new_manifest  = {}
copied_assets = 0
asset_warnings = []

used_assets.uniq.each do |src|
  basename = File.basename(src)
  dest = ASSETS_DIR.join(basename)

  if in_publish_assets?(src)
    # 이미 publish/assets/ 안에 있는 파일 — 사용자 직접 관리 영역. 매니페스트에 추가하지 않음.
    next
  end

  # 동일 basename 의 직접 관리 파일 보호
  if dest.exist? && !old_manifest.key?(basename)
    asset_warnings << "⚠️  '#{basename}' 가 이미 publish/assets/ 에 직접 존재합니다. 충돌 회피를 위해 자동 관리에서 제외합니다.\n    원본: #{src.relative_path_from(ROOT)}"
    next
  end

  if options[:dry_run]
    puts "would copy: #{src.relative_path_from(ROOT)} -> assets/#{basename}"
  else
    ASSETS_DIR.mkpath
    need_copy = !dest.exist? || dest.size != src.size || dest.mtime < src.mtime
    if need_copy
      FileUtils.cp(src, dest)
      File.utime(src.atime, src.mtime, dest)
      puts "copied: #{src.relative_path_from(ROOT)} -> assets/#{basename}" if options[:verbose]
      copied_assets += 1
    end
  end

  new_manifest[basename] = {
    "source"    => src.relative_path_from(ROOT).to_s,
    "synced_at" => Time.now.strftime("%Y-%m-%d"),
  }
end

asset_warnings.each { |w| warn w }

# 이전에 자동 관리되던 이미지가 더 이상 참조되지 않으면 정리
removed_assets = 0
(old_manifest.keys - new_manifest.keys).each do |orphan|
  orphan_path = ASSETS_DIR.join(orphan)
  next unless orphan_path.exist?
  if options[:dry_run]
    puts "would remove asset: assets/#{orphan}"
  else
    orphan_path.delete
    puts "removed: assets/#{orphan}" if options[:verbose]
  end
  removed_assets += 1
end

# 매니페스트 저장 (비어 있을 때도 작성해서 다음 실행에서 정리 기준이 되게 함)
unless options[:dry_run]
  ASSETS_MANIFEST.write(JSON.pretty_generate(new_manifest))
end

# ===============================================================
# 8. 요약
# ===============================================================
mode = options[:dry_run] ? "[DRY RUN] " : ""
puts "#{mode}✓ 노트   : #{added_notes} 발행 / #{removed_notes} 정리"
puts "#{mode}✓ 이미지 : #{copied_assets} 복사 / #{removed_assets} 정리 (관리: #{new_manifest.size}, 미발견: #{missing_refs.size})"
