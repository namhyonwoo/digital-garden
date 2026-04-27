# frozen_string_literal: true
#
# Obsidian 의 인라인 태그(#tag) 를 본문에서 추출해 note.tags 에 머지합니다.
# - 옵시디언 규칙: 태그는 영문/숫자/한글/하이픈/언더스코어/슬래시(중첩) 가능, 첫 글자는 문자
# - 코드 펜스(```), 인라인 코드(`...`), 마크다운 헤딩(##) 안의 # 은 무시
# - YAML frontmatter 의 기존 tags 와 합쳐 중복 제거, 알파벳/한글 정렬
#
# 결과: search-index.json 과 note 페이지에서 note.tags 가 인라인 태그까지 포함

module Jekyll
  class ObsidianInlineTagsExtractor
    # Obsidian 태그 매칭 — 코드/헤딩 외 본문에서만
    TAG_REGEX = /(?<![\w#`])#([\p{L}\p{N}][\p{L}\p{N}_\-\/]*)/u.freeze

    def self.extract(raw_content)
      return [] if raw_content.nil? || raw_content.empty?

      stripped = raw_content.dup

      # 1. 코드 펜스 제거 (``` ... ```, ~~~ ... ~~~)
      stripped.gsub!(/```[\s\S]*?```/m, "")
      stripped.gsub!(/~~~[\s\S]*?~~~/m, "")

      # 2. 인라인 코드 제거 (`...`)
      stripped.gsub!(/`[^`]+`/, "")

      # 3. 마크다운 헤딩의 선행 # 제거 (## 제목 → 제목)
      # 주의: Ruby 정규식 안에서 `#{...}` 는 문자열 보간이므로 [#] 로 감싸야 함
      stripped.gsub!(/^[ \t]{0,3}[#]{1,6}[ \t]+/m, "")

      stripped.scan(TAG_REGEX).flatten.uniq
    end
  end
end

Jekyll::Hooks.register :notes, :pre_render do |note|
  inline_tags = Jekyll::ObsidianInlineTagsExtractor.extract(note.content)
  next if inline_tags.empty?

  existing = Array(note.data["tags"]).map(&:to_s)
  merged = (existing + inline_tags).uniq.sort_by { |t| t.downcase }
  note.data["tags"] = merged
end
