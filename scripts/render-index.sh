#!/usr/bin/env bash
# Render the landing page into <site>/index.html from the index.html template:
# inject the packages table (built from the generated binary-*/Packages indexes),
# substitute the @@TOKENS@@ from conf/site.conf, and apply the selected colour
# theme (conf/themes/<name>.css). THEME may be overridden from the environment
# (e.g. the Makefile's `make build THEME=teal`).
#
# When the pool is empty the table falls back to a "No packages published yet."
# notice — unless DEMO_WHEN_EMPTY is set, in which case sample/demo rows are shown
# instead. That demo mode is used by `make serve` to preview the design of an
# empty repository locally; it is never invoked by the build, so the published
# site never contains the sample rows.
#
# Usage: render-index.sh <site>
# (architectures for the tagline come from conf/dists.conf, not argv — see below)
set -euo pipefail

SITE="${1:?site dir}"; shift || true
ARCHES=("$@")
[ ${#ARCHES[@]} -gt 0 ] || ARCHES=(amd64 arm64)

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$(dirname "$0")/dists-lib.sh"; dists_load "${DISTS_CONF:-$ROOT/conf/dists.conf}"
# DISTS/ARCHES now hold the config's values. gen-index.sh calls this script
# with $SITE only (no arch args), so the tagline's arches must come from
# config, not "$@" — this supersedes the positional-args fallback above.
read -ra ARCHES <<< "$ARCHES"

# extract one TSV line per stanza from every configured codename's generated
# Packages indexes, tagged with its release (codename); dedup identical
# artifacts (e.g. arch:all debs listed under every architecture, or the same
# package present in more than one release), then group by package+version
# into one row each — the releases and architectures each become their own
# tag group, and the .debs become a per-arch download menu. No indexes across
# any codename (empty preview dir) => no rows.
rows=""
tsv="$(
  for cn in $DISTS; do
    while IFS= read -r pf; do
      awk -v rel="$cn" '
        function emit(){ if(fn!="") print rel"\t"pkg"\t"ver"\t"arch"\t"size"\t"fn"\t"desc"\t"home;
                         pkg=ver=arch=size=fn=desc=home="" }
        /^Package:/{v=$0;sub(/^Package:[ \t]*/,"",v);pkg=v}
        /^Version:/{v=$0;sub(/^Version:[ \t]*/,"",v);ver=v}
        /^Architecture:/{v=$0;sub(/^Architecture:[ \t]*/,"",v);arch=v}
        /^Size:/{v=$0;sub(/^Size:[ \t]*/,"",v);size=v}
        /^Filename:/{v=$0;sub(/^Filename:[ \t]*/,"",v);fn=v}
        /^Description:/{v=$0;sub(/^Description:[ \t]*/,"",v);desc=v}
        /^Homepage:/{v=$0;sub(/^Homepage:[ \t]*/,"",v);home=v}
        /^[[:space:]]*$/{emit()} END{emit()}
      ' "$pf"
    done < <(find "$SITE/dists/$cn/main" -name Packages 2>/dev/null)
  done | sort -u
)"
if [ -n "$tsv" ]; then
  rows="$(printf '%s\n' "$tsv" | awk -F'\t' '
    function esc(s){ gsub(/&/,"\\&amp;",s); gsub(/</,"\\&lt;",s); gsub(/>/,"\\&gt;",s); return s }
    function hsize(b){ if(b+0>=1048576)return sprintf("%.1f MB",b/1048576);
                       else if(b+0>=1024)return sprintf("%.0f KB",b/1024); else return b" B" }
    {
      rel=$1; key=$2 SUBSEP $3
      if(!(key in seen)){ seen[key]=1; ord[++n]=key; kpkg[key]=$2; kver[key]=$3; kdesc[key]=$7; khome[key]=$8 }
      rk=key SUBSEP rel; if(!(rk in rseen)){ rseen[rk]=1; rels[key]=rels[key](rels[key]==""?"":" ")rel }
      ak=key SUBSEP $4; if(!(ak in aseen)){ aseen[ak]=1; arch[key]=arch[key](arch[key]==""?"":" ")$4 }
      asz[ak]=$5; afn[ak]=$6
    }
    END{
      for(i=1;i<=n;i++){ key=ord[i];
        m=split(arch[key],av," "); for(a=1;a<m;a++)for(b=a+1;b<=m;b++)if(av[b]<av[a]){t=av[a];av[a]=av[b];av[b]=t}
        r=split(rels[key],rv," "); for(a=1;a<r;a++)for(b=a+1;b<=r;b++)if(rv[b]<rv[a]){t=rv[a];rv[a]=rv[b];rv[b]=t}
        reltags=""; for(a=1;a<=r;a++) reltags=reltags "<span class=\"rel\">" esc(rv[a]) "</span>"
        tags=""; items=""
        for(a=1;a<=m;a++){ ak=key SUBSEP av[a]
          tags=tags "<span class=\"arch\">" esc(av[a]) "</span>"
          items=items "<a href=\"" esc(afn[ak]) "\" download><span class=\"a\">" esc(av[a]) "</span><span class=\"s\">" hsize(asz[ak]) "</span></a>" }
        home=""; if(khome[key]!=""){ lbl=khome[key]; sub(/^https?:\/\//,"",lbl); sub(/\/+$/,"",lbl);
          home="<a class=\"home\" href=\"" esc(khome[key]) "\">" esc(lbl) "</a>" }
        printf "            <details class=\"pkg\" name=\"packages\"><summary><span class=\"name\"><code>%s</code></span><span class=\"ver\">%s</span><span class=\"rels\">%s</span><span class=\"arches\">%s</span></summary><div class=\"pkg-body\"><p class=\"desc\">%s</p>%s<div class=\"downloads\">%s</div></div></details>\n", esc(kpkg[key]), esc(kver[key]), reltags, tags, esc(kdesc[key]), home, items
      }
    }')"
fi

# accordion list wrapper (each package is a <details>; styled by index.html)
list_open=$'      <div class="pkg-list">\n'
list_close=$'\n      </div>'

if [ -n "$rows" ]; then
  body="$list_open$rows$list_close"
elif [ -n "${DEMO_WHEN_EMPTY:-}" ]; then
  # Preview-only placeholder items so the landing page can be styled/themed with a
  # populated list on an empty repo. Never rendered by the build (see header).
  demo_rows=$'            <details class="pkg" name="packages"><summary><span class="name"><code>example-cli</code></span><span class="ver">1.4.0</span><span class="rels"><span class="rel">bookworm</span><span class="rel">trixie</span></span><span class="arches"><span class="arch">amd64</span><span class="arch">arm64</span></span></summary><div class="pkg-body"><p class="desc">Sample package \xe2\x80\x94 demo preview only</p><a class="home" href="#">github.com/example/example-cli</a><div class="downloads"><a href="#" download><span class="a">amd64</span><span class="s">742 KB</span></a><a href="#" download><span class="a">arm64</span><span class="s">698 KB</span></a></div></div></details>\n            <details class="pkg" name="packages"><summary><span class="name"><code>widget-daemon</code></span><span class="ver">0.9.2</span><span class="rels"><span class="rel">bookworm</span></span><span class="arches"><span class="arch">amd64</span></span></summary><div class="pkg-body"><p class="desc">Another sample package for layout preview</p><a class="home" href="#">example.com/widget-daemon</a><div class="downloads"><a href="#" download><span class="a">amd64</span><span class="s">1.3 MB</span></a></div></div></details>'
  note=$'      <p style="margin:0 0 1rem;color:var(--ink-soft);font-size:.85rem">Demo preview \xe2\x80\x94 sample data shown because the repository has no packages yet. Visible only via <code>make serve</code>; it is never part of the published site.</p>\n'
  body="$note$list_open$demo_rows$list_close"
else
  body='      <p class="empty">No packages published yet.</p>'
fi

# --- site config (conf/site.conf), with THEME overridable from the env ---
theme_env="${THEME:-}"
[ -f "$ROOT/conf/site.conf" ] && . "$ROOT/conf/site.conf"
[ -n "$theme_env" ] && THEME="$theme_env"
: "${SITE_TITLE:=autobott}"
: "${SITE_TAGLINE:=A signed APT repository for Debian and Ubuntu}"
: "${REPO_URL:=https://ansible-autobott.github.io/debian-repo}"
: "${GITHUB_URL:=https://github.com/ansible-autobott/debian-repo}"
: "${KEYRING_FILE:=autobott-archive-keyring.gpg}"
: "${SOURCES_FILE:=autobott.sources}"
: "${THEME:=violet}"

gh="${GITHUB_URL#http://}"; gh="${gh#https://}"   # link label without the scheme

# architecture list for the tagline: "<code>a</code> and <code>b</code>"
arches_html=""; n=${#ARCHES[@]}; i=0
for a in "${ARCHES[@]}"; do
  i=$((i+1))
  if [ "$i" -gt 1 ]; then
    if [ "$i" -eq "$n" ] && [ "$n" -eq 2 ]; then arches_html+=" and "; else arches_html+=", "; fi
  fi
  arches_html+="<code>$a</code>"
done

# colour theme: violet is built into the template; alternates are CSS files
theme_css=""
if [ "$THEME" != "violet" ]; then
  tf="$ROOT/conf/themes/$THEME.css"
  if [ -f "$tf" ]; then theme_css="$(cat "$tf")"
  else echo "⚠️  unknown theme '$THEME' (no $tf) — using built-in violet" >&2; fi
fi

# --- substitute tokens + packages table + theme into the template ---
content="$(cat "$ROOT/index.html")"
content=${content//'@@SITE_TITLE@@'/$SITE_TITLE}
content=${content//'@@SITE_TAGLINE@@'/$SITE_TAGLINE}
content=${content//'@@REPO_URL@@'/$REPO_URL}
content=${content//'@@KEYRING_FILE@@'/$KEYRING_FILE}
content=${content//'@@SOURCES_FILE@@'/$SOURCES_FILE}
content=${content//'@@GITHUB_URL@@'/$GITHUB_URL}
content=${content//'@@GITHUB_LABEL@@'/$gh}
content=${content//'@@ARCHES@@'/$arches_html}
# Inject the table by splitting on the marker instead of ${//}: bash 5.2+ treats
# an unescaped '&' in a ${//} replacement as the matched text, which would corrupt
# any package field escaped to an HTML entity (& < > -> &amp; &lt; &gt;).
content="${content%%'<!-- PACKAGES_TABLE -->'*}${body}${content#*'<!-- PACKAGES_TABLE -->'}"
content=${content//'/* @@THEME@@ */'/$theme_css}
printf '%s\n' "$content" > "$SITE/index.html"
