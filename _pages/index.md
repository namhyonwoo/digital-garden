---
layout: page
title: Home
id: home
permalink: /
---

<section class="home-hero">
  <h1>Welcome! 🌱</h1>
  <p>
    생각과 기록을 심어 가꾸는 디지털 가든입니다.
    아래에서 최근 업데이트된 노트부터 둘러보세요.
  </p>
</section>

## 최근 업데이트된 노트

<ul class="post-list">
  {% assign recent_notes = site.notes | sort: "last_modified_at_timestamp" | reverse %}
  {% for note in recent_notes limit: 8 %}
    <li>
      <span class="post-list__date">{{ note.last_modified_at | date: "%Y-%m-%d" }}</span>
      <a class="internal-link" href="{{ site.baseurl }}{{ note.url }}">{{ note.title }}</a>
    </li>
  {% endfor %}
</ul>

{% include adsense.html position="inline" %}

이 디지털 가든은 오픈소스 [Jekyll 템플릿](https://github.com/maximevaillancourt/digital-garden-jekyll-template) 위에 모던 블로그 스타일을 얹어 꾸몄습니다.
