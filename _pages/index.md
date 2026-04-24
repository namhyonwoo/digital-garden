---
layout: page
title: Home
id: home
permalink: /
---

<section class="home-hero">
  <p class="home-hero__eyebrow">Digital garden</p>
  <h1>찾고 싶은 노트를 바로 여는 홈</h1>
  <p>
    제목, 태그, 별칭을 기준으로 빠르게 찾을 수 있게 구성했습니다.
    정적 사이트지만 빌드 시점에 인덱스를 만들어 브라우저에서 즉시 필터링합니다.
  </p>

  <div class="search-shell" role="search">
    <label class="search-shell__label" for="home-search-input">노트 검색</label>
    <input
      id="home-search-input"
      class="search-shell__input"
      type="search"
      inputmode="search"
      placeholder="예: shipping, 건강, #backend, first note"
      autocomplete="off"
      spellcheck="false"
    >
    <p class="search-shell__hint">
      제목 우선, 태그와 별칭도 같이 찾습니다. 태그는 <code>#backend</code>처럼 입력하거나 아래 칩을 눌러보세요.
    </p>
  </div>
</section>

<section class="home-tags" aria-labelledby="home-tags-title">
  <div class="home-section__header">
    <h2 id="home-tags-title">추천 태그</h2>
    <p>기존 노트들에 태그를 넣어 실제 검색 결과가 보이도록 구성했습니다.</p>
  </div>
  <div class="tag-chip-row" id="search-tag-bar">
    <button class="tag-chip is-active" type="button" data-tag="">전체</button>
  </div>
</section>

<section class="search-results" aria-labelledby="search-results-title">
  <div class="home-section__header">
    <h2 id="search-results-title">검색 결과</h2>
    <p id="search-results-meta">최근 업데이트된 노트를 먼저 보여줍니다.</p>
  </div>

  <ul class="post-list post-list--search" id="search-results-list">
    {% assign recent_notes = site.notes | sort: "last_modified_at_timestamp" | reverse %}
    {% for note in recent_notes limit: 8 %}
      <li>
        <div class="post-list__meta">
          <span class="post-list__date">{{ note.last_modified_at | date: "%Y-%m-%d" }}</span>
        </div>
        <a class="internal-link" href="{{ site.baseurl }}{{ note.url }}">{{ note.title | default: note.basename_without_ext }}</a>
        {% if note.tags and note.tags.size > 0 %}
          <div class="post-list__tags">
            {% for tag in note.tags limit: 4 %}
              <span class="result-tag">#{{ tag }}</span>
            {% endfor %}
          </div>
        {% endif %}
      </li>
    {% endfor %}
  </ul>

  <p class="search-results__empty" id="search-results-empty" hidden>일치하는 노트를 찾지 못했습니다.</p>
</section>

{% include adsense.html position="inline" %}

이 디지털 가든은 오픈소스 [Jekyll 템플릿](https://github.com/maximevaillancourt/digital-garden-jekyll-template) 위에 검색 중심의 홈 경험을 얹어 꾸몄습니다.

<noscript>
  <p>검색 인터랙션은 JavaScript가 필요하지만, 최근 노트 목록은 그대로 둘러볼 수 있습니다.</p>
</noscript>

<script>
  (function () {
    var searchInput = document.getElementById('home-search-input');
    var resultsList = document.getElementById('search-results-list');
    var resultsMeta = document.getElementById('search-results-meta');
    var emptyState = document.getElementById('search-results-empty');
    var tagBar = document.getElementById('search-tag-bar');

    if (!searchInput || !resultsList || !resultsMeta || !emptyState || !tagBar) return;

    var searchIndexUrl = {{ "/search-index.json" | relative_url | jsonify }};
    var notes = [];
    var activeTag = '';

    var normalize = function (value) {
      return (value || '').toString().trim().toLowerCase();
    };

    var escapeHtml = function (value) {
      return (value || '')
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;')
        .replace(/'/g, '&#39;');
    };

    var buildTagMarkup = function (tags) {
      if (!tags || !tags.length) return '';
      return '<div class="post-list__tags">' + tags.slice(0, 5).map(function (tag) {
        return '<span class="result-tag">#' + escapeHtml(tag) + '</span>';
      }).join('') + '</div>';
    };

    var renderResults = function (items, options) {
      resultsList.innerHTML = items.map(function (note) {
        var excerpt = note.excerpt ? '<p class="post-list__excerpt">' + escapeHtml(note.excerpt) + '</p>' : '';
        return '' +
          '<li>' +
            '<div class="post-list__meta">' +
              '<span class="post-list__date">' + escapeHtml(note.updated_at || '') + '</span>' +
            '</div>' +
            '<a class="internal-link" href="' + escapeHtml(note.url) + '">' + escapeHtml(note.title) + '</a>' +
            buildTagMarkup(note.tags) +
            excerpt +
          '</li>';
      }).join('');

      emptyState.hidden = items.length > 0;
      if (options && options.metaText) {
        resultsMeta.textContent = options.metaText;
      }
    };

    var renderTagChips = function (items) {
      var counts = {};

      items.forEach(function (note) {
        (note.tags || []).forEach(function (tag) {
          counts[tag] = (counts[tag] || 0) + 1;
        });
      });

      var sortedTags = Object.keys(counts).sort(function (left, right) {
        if (counts[right] !== counts[left]) return counts[right] - counts[left];
        return left.localeCompare(right);
      }).slice(0, 10);

      var chips = ['<button class="tag-chip is-active" type="button" data-tag="">전체</button>'];
      sortedTags.forEach(function (tag) {
        chips.push('<button class="tag-chip" type="button" data-tag="' + escapeHtml(tag) + '">#' + escapeHtml(tag) + '</button>');
      });
      tagBar.innerHTML = chips.join('');
    };

    var scoreNote = function (note, query, tagFilter) {
      var normalizedQuery = normalize(query).replace(/^#/, '');
      var title = normalize(note.title);
      var excerpt = normalize(note.excerpt);
      var tags = (note.tags || []).map(normalize);
      var aliases = (note.aliases || []).map(normalize);
      var score = 0;

      if (tagFilter && tags.indexOf(normalize(tagFilter)) === -1) return -1;
      if (!normalizedQuery) return score;

      if (title === normalizedQuery) score += 120;
      else if (title.indexOf(normalizedQuery) !== -1) score += 80;

      tags.forEach(function (tag) {
        if (tag === normalizedQuery) score += 70;
        else if (tag.indexOf(normalizedQuery) !== -1) score += 36;
      });

      aliases.forEach(function (alias) {
        if (alias === normalizedQuery) score += 54;
        else if (alias.indexOf(normalizedQuery) !== -1) score += 28;
      });

      if (excerpt.indexOf(normalizedQuery) !== -1) score += 12;
      return score;
    };

    var applySearch = function () {
      var query = searchInput.value || '';
      var filtered = notes
        .map(function (note) {
          return { note: note, score: scoreNote(note, query, activeTag) };
        })
        .filter(function (entry) {
          if (!normalize(query) && !activeTag) return true;
          return entry.score > 0 || (!normalize(query) && activeTag && entry.score >= 0);
        })
        .sort(function (left, right) {
          if (right.score !== left.score) return right.score - left.score;
          return (right.note.updated_at || '').localeCompare(left.note.updated_at || '');
        })
        .map(function (entry) { return entry.note; });

      var limited = filtered.slice(0, 12);
      var stateText;
      if (normalize(query) || activeTag) {
        var descriptor = activeTag ? '태그 #' + activeTag : '검색어 "' + query + '"';
        if (normalize(query) && activeTag) descriptor = '검색어 "' + query + '" + 태그 #' + activeTag;
        stateText = limited.length + '개의 결과를 보여줍니다. 기준: ' + descriptor;
      } else {
        stateText = '최근 업데이트된 노트를 먼저 보여줍니다.';
      }

      renderResults(limited, { metaText: stateText });
    };

    tagBar.addEventListener('click', function (event) {
      var button = event.target.closest('[data-tag]');
      if (!button) return;

      activeTag = button.getAttribute('data-tag') || '';
      Array.prototype.forEach.call(tagBar.querySelectorAll('.tag-chip'), function (chip) {
        chip.classList.toggle('is-active', chip === button);
      });
      applySearch();
    });

    searchInput.addEventListener('input', applySearch);

    fetch(searchIndexUrl)
      .then(function (response) {
        if (!response.ok) throw new Error('search index load failed');
        return response.json();
      })
      .then(function (data) {
        notes = Array.isArray(data) ? data : [];
        renderTagChips(notes);
        applySearch();
      })
      .catch(function () {
        resultsMeta.textContent = '검색 인덱스를 불러오지 못해 최근 노트 목록만 표시합니다.';
      });
  })();
</script>
