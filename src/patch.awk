# POSIX awk: config lines MODIFIERS:KEY=VALUE; base KCM as second input.
# VALUE = R_KEYCODE, F_KEYCODE, U_XXXX or NONE. No arbitrary source text.
# The caller rejects input containing NUL first (busybox awk would split the line there).
function fail(s) { print s > "/dev/stderr"; bad=1; exit 1 }
function trim(s) { sub(/^[ \t\r]+/,"",s); sub(/[ \t\r]+$/,"",s); return s }
function validkey(s) {return s ~ /^([A-Z]|0|4|SPACE|DEL|ENTER)$/}
function code(s) {return s ~ /^([A-Z]|[0-9]|DPAD_UP|DPAD_DOWN|DPAD_LEFT|DPAD_RIGHT|DPAD_CENTER|TAB|ESCAPE|MOVE_HOME|MOVE_END|PAGE_UP|PAGE_DOWN|INSERT|FORWARD_DEL|DEL|ENTER|SPACE|LANGUAGE_SWITCH|SWITCH_CHARSET|F[1-9]|F1[0-2]|COMMA|PERIOD|MINUS|EQUALS|LEFT_BRACKET|RIGHT_BRACKET|BACKSLASH|SEMICOLON|APOSTROPHE|SLASH|GRAVE|AT|POUND|PLUS|STAR|BACK|MENU|SEARCH|HOME)$/}
# Modifier order is normalized, not dependent on user spelling.
function init( i) { nmod=split("shift lshift rshift alt lalt ralt ctrl lctrl rctrl meta lmeta rmeta sym fn capslock numlock scrolllock",mods," "); for(i=1;i<=nmod;i++) rank[mods[i]]=i }
function canonical(s, a,b,i,n,j,r,g) {
 if(s=="base") return s
 n=split(s,a,"+"); if(n<1 || n>nmod) return ""
 for(i=1;i<=n;i++){if(!(a[i] in rank) || b[a[i]]++) return ""}
 for(i=1;i<=12;i+=3) if(b[mods[i]] && (b[mods[i+1]] || b[mods[i+2]])) return ""
 r=""; for(i=1;i<=nmod;i++) if(b[mods[i]]) r=r (r==""?"":"+") mods[i]
 return r
}
function contains(s,t) { return index("+" s "+","+" t "+")>0 }
# A is stricter than B when it requires every modifier of B and at least one more.
function implies(a,b, q,n,i,t,g) {
 if(b=="base")return 1; if(a=="base")return 0
 n=split(b,q,"+"); for(i=1;i<=n;i++){t=q[i]; if(contains(a,t))continue; if(t ~ /^(shift|alt|ctrl|meta)$/ && (contains(a,"l" t)||contains(a,"r" t)))continue; return 0} return 1
}
function behavior(v, h) {
 if(v=="NONE")return "none"
 if(substr(v,1,2)=="R_" && code(substr(v,3)))return "replace " substr(v,3)
 if(substr(v,1,2)=="F_" && code(substr(v,3)))return "fallback " substr(v,3)
 if(v ~ /^U_[0-9A-F][0-9A-F][0-9A-F][0-9A-F]$/){h=substr(v,3); if(h=="0000" || h ~ /^D[89A-F]/)return ""; return "\047\\u" h "\047"}
 return ""
}
function addrule(p,v, i) {if(p in pos)fail("Duplicate property " block ":" p); pos[p]=++nr; rp[nr]=p; rv[nr]=v}
function flush( i,j,k,p,v,ok,remaining,best,any,vnew) {
 # Unmodified blocks are emitted byte-for-byte apart from line endings.
 if(!(block in touched)){for(i=1;i<=nl;i++)print lines[i]; return}
 for(i=1;i<=nl;i++){
  v=trim(lines[i]); if(v=="" || v ~ /^#/){print lines[i];continue}
  j=index(v,":"); if(!j)fail("Unsupported property in " block ": " v)
  p=trim(substr(v,1,j-1)); v=trim(substr(v,j+1)); k=split(p,plist,",");
  for(j=1;j<=k;j++){
   p=trim(plist[j]); if(p=="label" || p=="number"){print "    " p ": " v;continue}
   p=canonical(p); if(p=="")fail("Unsupported modifier in " block)
   if((block SUBSEP p) in cfg){vnew=behavior(cfg[block,p]); addrule(p,vnew); done[block,p]=1} else addrule(p,v)
  }
 }
 for(i=1;i<=nc;i++) if(ck[i]==block && !((block SUBSEP cl[i]) in done)){p=cl[i]; addrule(p,behavior(cfg[block,p]));done[block,p]=1}
 # Stable topological order, broad rules before more specific rules. Preserve
 # original order wherever possible. New incomparable rules follow old ones.
 for(i=1;i<=nr;i++){degree[i]=0;for(j=1;j<=nr;j++)if(i!=j && implies(rp[i],rp[j])&&!implies(rp[j],rp[i])){edge[j,i]=1;degree[i]++}}
 remaining=nr; while(remaining){best=0; for(i=1;i<=nr;i++)if(!em[i] && degree[i]==0){best=i;break}
  if(!best)fail("Modifier ordering failed"); print "    " rp[best] ": " rv[best];em[best]=1;remaining--
  for(i=1;i<=nr;i++)if((best SUBSEP i) in edge)degree[i]--
 }
}
function clearblock( i){for(i in lines)delete lines[i];for(i in pos)delete pos[i];for(i in rp)delete rp[i];for(i in rv)delete rv[i];for(i in em)delete em[i];for(i in degree)delete degree[i];for(i in edge)delete edge[i];nl=nr=0}
BEGIN{init()}
FNR==NR {if($0=="# config")next; if(NF!=1)fail("Bad config line"); n=split($0,parts,"[:=]");if(n!=3)fail("Bad assignment"); p=canonical(parts[1]); k=parts[2];v=parts[3];if(p==""||p!=parts[1]||!validkey(k)||behavior(v)==""||((k SUBSEP p) in cfg))fail("Invalid or duplicate assignment: " $0);cfg[k,p]=v;touched[k]=1;ck[++nc]=k;cl[nc]=p; if(nc>1500)fail("Too many assignments (1500 max)");next}
# The AOSP tokenizer treats CR as whitespace; only a trailing CR (CRLF files) is accepted here
# and the output uses LF. Anything the generator does not recognise fails the run instead of
# being copied through, so an unexpected original can never yield a silently broken map.
{ sub(/\r$/, ""); if (index($0, "\r")) fail("Unsupported carriage return at line " FNR) }
/^[ \t]*key[ \t]+[^ \t{]+[ \t]+\{[ \t]*(#.*)?$/ {if(block!="")fail("Nested key block");block=$2;if(block in seen)fail("Repeated key block " block);seen[block]=1;clearblock(); print;next}
/^[ \t]*\}[ \t]*(#.*)?$/ {if(block=="")fail("Unexpected closing brace");flush();block="";print;next}
{if(block!="")lines[++nl]=$0;else if($0 ~ /^[ \t]*(#.*)?$/ || $1=="type" || $1=="map")print;else fail("Unsupported top-level line " FNR ": " $0)}
END{if(bad)exit 1;if(block!="")fail("Unclosed key block"); for(i=1;i<=nc;i++){k=ck[i];if(!(k in seen)){block=k;clearblock();print "key " k " {";flush();print "}";seen[k]=1;block=""}} for(i=1;i<=nc;i++) {k=ck[i];p=cl[i];if(!((k SUBSEP p) in done))fail("Missing assignment");print "# KEY2_V4 " p ":" k "=" cfg[k,p]}}
