#!/usr/bin/env ruby
# frozen_string_literal: true
#
# 옵시디언 볼트 전체를 스캔해서 frontmatter 에 `publish: true` 가 있는 노트를
# publish/_notes/ 로 동기화합니다.
#
# 사용법:
#   ruby bin/sync_publish.rb              # 실제 동기화
#   ruby bin/sync_publish.rb --dry-run    # 변경 없이 미리보기만
#   ruby bin/sync_publish.rb --quiet      # 로그 줄이기
#
# 동작 요약:
#   1. 볼트의 모든 .md 를 훑어 publish: true 인 노트를 수집
#   2. 기존 _notes/ 에서 `_synced_from` 마커가 있는 파일은 삭제 (이전 동기화 결과 정리)
#   3. 수집된 노트들을 새로 _notes/ 로 복사하면서 마커를 추가
#   4. 마커가 없는 파일(직접 만든 노트, 템플릿 노트)은 절대 건드리지 않음
#
# 자동 동기화된 파일과 직접 만든 파일을 구분하는 키: `_synced_from`
# 이 키는 검색 인덱스 출력(`title/url/tags/aliases/excerpt/updated_at`)에는 노출되지 않습니다.

require "yaml"
require "date"
require "fileutils"
require "pathname"
require "optparse"

ROOT = Pathname.new(File.expand_path("../..", __dir__))
PUBLISH_DIR = ROOT.join("publish")
NOTES_DIR = PUBLISH_DIR.join("_notes")
EXCLUDED_DIRS = %w[publish .obsidian .trash .git node_modules vendor _site .bundle].freeze
MARKER = "_synced_from"

options = { dry_run: false, verbose: true }
OptionParser.new do |opts|
  opts.banner = "Usage: ruby bin/sync_publish.rb [options]"
  opts.on("--dry-run", "변경 없이 미리보기") { options[:dry_run] = true }
  opts.on("-q", "--quiet", "로그 최소화")    { options[:verbose] = false }
  opts.on("-h", "--help", "도움말") { puts opts; exit }
end.parse!

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

def excluded?(path)
  rel = path.to_s
  EXCLUDED_DIRS.any? do |d|
    rel.include?("/#{d}/") || rel.start_with?("#{ROOT}/#{d}/")
  end
end

# ---------------------------------------------------------------
# 1. 발행 대상 수집
# ---------------------------------------------------------------
publishable = []
Pathname.glob(ROOT.join("**/*.md")) do |path|
  next if excluded?(path)
  next unless path.file?

  fm, body = parse_frontmatter(path.read)
  next unless fm.is_a?(Hash) && fm["publish"] == true

  publishable << { path: path, frontmatter: fm, body: body }
end

# ---------------------------------------------------------------
# 2. 슬러그 결정 + 충돌 검사
# ---------------------------------------------------------------
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

# ---------------------------------------------------------------
# 3. 직접 만든 노트와의 충돌 방지
# ---------------------------------------------------------------
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

# ---------------------------------------------------------------
# 4. 이전에 동기화된 파일 정리
# ---------------------------------------------------------------
old_synced = []
NOTES_DIR.glob("**/*.md") do |path|
  fm, _ = parse_frontmatter(path.read)
  old_synced << path if fm.is_a?(Hash) && fm[MARKER]
end

removed = 0
old_synced.each do |path|
  rel = path.relative_path_from(NOTES_DIR)
  if options[:dry_run]
    puts "would remove: _notes/#{rel}"
  else
    path.delete
    puts "removed: _notes/#{rel}" if options[:verbose]
  end
  removed += 1
end

# ---------------------------------------------------------------
# 5. 새 동기화
# ---------------------------------------------------------------
FileUtils.mkdir_p(NOTES_DIR) unless options[:dry_run]
added = 0
publishable.each do |item|
  fm = item[:frontmatter].dup
  fm.delete("publish")
  fm[MARKER] = item[:path].relative_path_from(ROOT).to_s

  out_path = NOTES_DIR.join("#{item[:slug]}.md")
  yaml_str = fm.to_yaml.sub(/^---\n/, "").sub(/\n\Z/, "\n")
  payload = "---\n#{yaml_str}---\n\n#{item[:body]}"

  if options[:dry_run]
    puts "would write: _notes/#{item[:slug]}.md  (from #{item[:path].relative_path_from(ROOT)})"
  else
    out_path.parent.mkpath
    out_path.write(payload)
    File.utime(item[:path].atime, item[:path].mtime, out_path)
    puts "synced: #{item[:path].relative_path_from(ROOT)} -> _notes/#{item[:slug]}.md" if options[:verbose]
  end
  added += 1
end

# ---------------------------------------------------------------
# 6. 요약
# ---------------------------------------------------------------
mode = options[:dry_run] ? "[DRY RUN] " : ""
puts "#{mode}✓ #{added} 개 발행 / #{removed} 개 이전 동기화 정리"
