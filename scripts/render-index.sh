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
        function emit(){ if(fn!="") print rel"\t"pkg"\t"ver"\t"arch"\t"size"\t"fn"\t"desc"\t"home"\t"sha;
                         pkg=ver=arch=size=fn=desc=home=sha="" }
        /^Package:/{v=$0;sub(/^Package:[ \t]*/,"",v);pkg=v}
        /^Version:/{v=$0;sub(/^Version:[ \t]*/,"",v);ver=v}
        /^Architecture:/{v=$0;sub(/^Architecture:[ \t]*/,"",v);arch=v}
        /^Size:/{v=$0;sub(/^Size:[ \t]*/,"",v);size=v}
        /^Filename:/{v=$0;sub(/^Filename:[ \t]*/,"",v);fn=v}
        /^SHA256:/{v=$0;sub(/^SHA256:[ \t]*/,"",v);sha=v}
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
    function srt(a,c,   i,j,t){ for(i=1;i<c;i++)for(j=i+1;j<=c;j++)if(a[j]<a[i]){t=a[i];a[i]=a[j];a[j]=t} }
    function dllink(rak,ar){ return "<a href=\"" esc(afn[rak]) "\" download><span class=\"a\">" esc(ar) "</span><span class=\"s\">" hsize(asz[rak]) "</span></a>" }
    {
      rel=$1; key=$2 SUBSEP $3
      if(!(key in seen)){ seen[key]=1; ord[++n]=key; kpkg[key]=$2; kver[key]=$3; kdesc[key]=$7; khome[key]=$8 }
      rk=key SUBSEP rel; if(!(rk in rseen)){ rseen[rk]=1; rels[key]=rels[key](rels[key]==""?"":" ")rel }
      ak=key SUBSEP $4; if(!(ak in aseen)){ aseen[ak]=1; arch[key]=arch[key](arch[key]==""?"":" ")$4 }
      # per (package, release, arch): the real pool file, its size and content hash
      rak=key SUBSEP rel SUBSEP $4; afn[rak]=$6; asz[rak]=$5; ash[rak]=$9
      rark=rk SUBSEP $4; if(!(rark in raseen)){ raseen[rark]=1; rarch[rk]=rarch[rk](rarch[rk]==""?"":" ")$4 }
    }
    END{
      for(i=1;i<=n;i++){ key=ord[i];
        m=split(arch[key],av," "); srt(av,m)
        r=split(rels[key],rv," "); srt(rv,r)
        reltags=""; for(a=1;a<=r;a++) reltags=reltags "<span class=\"rel\">" esc(rv[a]) "</span>"
        tags=""; for(a=1;a<=m;a++) tags=tags "<span class=\"arch\">" esc(av[a]) "</span>"
        # Each release’s signature is its sorted "arch:sha256;" set. When every
        # release shares one signature (a release-agnostic "any" build, or a
        # single-release package) the downloads stay one flat per-arch list. Any
        # divergence — a different per-arch build, or different arch coverage —
        # groups the downloads by release so every distinct build is reachable.
        grouped=0; sig="";
        for(a=1;a<=r;a++){ rk=key SUBSEP rv[a]; rm=split(rarch[rk],ra," "); srt(ra,rm); s="";
          for(b=1;b<=rm;b++) s=s ra[b] ":" ash[rk SUBSEP ra[b]] ";";
          if(a==1) sig=s; else if(s!=sig) grouped=1 }
        if(grouped){
          dl="<div class=\"downloads-by-rel\">";
          for(a=1;a<=r;a++){ rk=key SUBSEP rv[a]; rm=split(rarch[rk],ra," "); srt(ra,rm);
            dl=dl "<div class=\"rel-group\"><span class=\"rel-h\">" esc(rv[a]) "</span><div class=\"downloads\">";
            for(b=1;b<=rm;b++) dl=dl dllink(rk SUBSEP ra[b], ra[b]);
            dl=dl "</div></div>" }
          dl=dl "</div>";
        } else {
          dl="<div class=\"downloads\">";
          for(a=1;a<=m;a++) for(c=1;c<=r;c++){ rak=key SUBSEP rv[c] SUBSEP av[a];
            if(rak in afn){ dl=dl dllink(rak, av[a]); break } }
          dl=dl "</div>";
        }
        home=""; if(khome[key]!=""){ lbl=khome[key]; sub(/^https?:\/\//,"",lbl); sub(/\/+$/,"",lbl);
          home="<a class=\"home\" href=\"" esc(khome[key]) "\">" esc(lbl) "</a>" }
        printf "            <details class=\"pkg\" name=\"packages\"><summary><span class=\"name\"><code>%s</code></span><span class=\"ver\">%s</span><span class=\"rels\">%s</span><span class=\"arches\">%s</span></summary><div class=\"pkg-body\"><p class=\"desc\">%s</p>%s%s</div></details>\n", esc(kpkg[key]), esc(kver[key]), reltags, tags, esc(kdesc[key]), home, dl
      }
    }')"
fi

# accordion list wrapper (each package is a <details>; styled by index.html)
list_open=$'      <div class="pkg-list">\n'
list_close=$'\n      </div>'

# codenames the demo's placeholder packages occupy — must match the release tags
# used in demo_rows below. Lets the suite picker gate on demo content in `make
# serve` (where the real pool, and thus $tsv, is empty). Empty outside demo mode.
demo_cn=""
if [ -n "$rows" ]; then
  body="$list_open$rows$list_close"
elif [ -n "${DEMO_WHEN_EMPTY:-}" ]; then
  demo_cn="trixie forky"
  # Preview-only placeholder items so the landing page can be styled/themed with a
  # populated list on an empty repo. Never rendered by the build (see header).
  demo_rows=$'            <details class="pkg" name="packages"><summary><span class="name"><code>example-cli</code></span><span class="ver">1.4.0</span><span class="rels"><span class="rel">trixie</span><span class="rel">forky</span></span><span class="arches"><span class="arch">amd64</span><span class="arch">arm64</span></span></summary><div class="pkg-body"><p class="desc">Sample package with per-release builds \xe2\x80\x94 demo preview only</p><a class="home" href="#">github.com/example/example-cli</a><div class="downloads-by-rel"><div class="rel-group"><span class="rel-h">trixie</span><div class="downloads"><a href="#" download><span class="a">amd64</span><span class="s">742 KB</span></a><a href="#" download><span class="a">arm64</span><span class="s">698 KB</span></a></div></div><div class="rel-group"><span class="rel-h">forky</span><div class="downloads"><a href="#" download><span class="a">amd64</span><span class="s">750 KB</span></a><a href="#" download><span class="a">arm64</span><span class="s">705 KB</span></a></div></div></div></div></details>\n            <details class="pkg" name="packages"><summary><span class="name"><code>widget-daemon</code></span><span class="ver">0.9.2</span><span class="rels"><span class="rel">trixie</span><span class="rel">forky</span></span><span class="arches"><span class="arch">amd64</span></span></summary><div class="pkg-body"><p class="desc">Release-agnostic sample \xe2\x80\x94 same build in every suite</p><a class="home" href="#">example.com/widget-daemon</a><div class="downloads"><a href="#" download><span class="a">amd64</span><span class="s">1.3 MB</span></a></div></div></details>'
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

# --- "Add the repository" step: a CSS-only suite picker (issue #2) ---
# One radio per publishable suite — the rolling aliases first (each showing its
# target codename as a sub-label), then the real codenames — each revealing an
# inline snippet that writes autobott.sources with that suite's Suites: value.
# Pure CSS + static markup so it works on GitHub Pages; the copy-button JS
# enhances every block unchanged. Suites come from conf/dists.conf, so adding a
# release or alias needs no template edit.
#
# A suite is offered only when its release carries at least one package: a
# codename by its own pool, an alias by its target codename's pool. Empty
# releases are a dead end to install from, so we hide them (aliases included).
# The populated set is the codenames (field 1) seen in the aggregated $tsv above;
# in demo mode $tsv is empty, so demo_cn stands in for the placeholder content.
# HTML-escape for <code> text. The '\&' in each replacement is required: bash 5.2+
# treats a bare '&' in a ${//} replacement as the matched text (see the marker-split
# note below), which would drop the entity's ampersand. '&' must be escaped first.
htesc() { local s=$1; s=${s//&/\&amp;}; s=${s//</\&lt;}; s=${s//>/\&gt;}; printf '%s' "$s"; }

populated_cn=" $(printf '%s\n' "$tsv" | awk -F'\t' 'NF{print $1}' | sort -u | tr '\n' ' ') "
[ -n "$demo_cn" ] && populated_cn=" $demo_cn "

su_names=(); su_subs=()
while read -r al tgt; do [ -n "$al" ] || continue; su_names+=("$al"); su_subs+=("$tgt"); done < <(alias_pairs)
for cn in $DISTS; do su_names+=("$cn"); su_subs+=(""); done

radios=""; su_tabs=""; su_cmds=""; su_rules=""; su_first=1
for idx in "${!su_names[@]}"; do
  s="${su_names[$idx]}"; sub="${su_subs[$idx]}"
  # the release this suite installs from: a codename installs from its own pool;
  # an alias installs from its target codename ($sub). Offer it only if that
  # release carries a package.
  target_cn="${sub:-$s}"
  case "$populated_cn" in *" $target_cn "*) ;; *) continue;; esac
  checked=""; [ "$su_first" = 1 ] && { checked=" checked"; su_first=0; }
  radios+="        <input class=\"suite-radio\" type=\"radio\" name=\"suite\" id=\"su-$s\"$checked>"$'\n'
  sublbl=""; [ -n "$sub" ] && sublbl="<span class=\"suite-sub\">$sub</span>"
  su_tabs+="          <label class=\"suite-lbl\" for=\"su-$s\">$s$sublbl</label>"$'\n'
  snippet="sudo tee /etc/apt/sources.list.d/$SOURCES_FILE >/dev/null <<'EOF'
Types: deb
URIs: $REPO_URL
Suites: $s
Components: main
Architectures: ${ARCHES[*]}
Signed-By: /etc/apt/keyrings/$KEYRING_FILE
EOF"
  su_cmds+="        <div class=\"cmd suite-cmd\" data-suite=\"$s\"><pre><code>$(htesc "$snippet")</code></pre></div>"$'\n'
  su_rules+="    #su-$s:checked ~ .suite-cmd[data-suite=\"$s\"] { display:block; }
    #su-$s:checked ~ .suite-tabs .suite-lbl[for=\"su-$s\"] { color:var(--ink); background:var(--accent-tint); box-shadow:inset 0 0 0 1.5px var(--accent); }
    #su-$s:focus-visible ~ .suite-tabs .suite-lbl[for=\"su-$s\"] { outline:2.5px solid var(--accent); outline-offset:2px; }"$'\n'
done
if [ -z "$radios" ]; then
  # no release carries a package yet — nothing installable, so stand a short note
  # in for the picker rather than render an empty control.
  add_repo='<p class="no-suites">No releases published yet.</p>'
else
  add_repo="<div class=\"suite-pick\">
$radios        <div class=\"suite-tabs\" role=\"radiogroup\" aria-label=\"Release or suite to track\">
$su_tabs        </div>
$su_cmds        <style>
$su_rules        </style>
      </div>"
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
content="${content%%'<!-- ADD_REPO -->'*}${add_repo}${content#*'<!-- ADD_REPO -->'}"
content=${content//'/* @@THEME@@ */'/$theme_css}
printf '%s\n' "$content" > "$SITE/index.html"
