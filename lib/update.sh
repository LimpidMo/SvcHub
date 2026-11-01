# SvcHub 公共库：二进制更新（GitHub release 版本探测、下载、校验、解包、替换）。
# 由 lib.sh 按序 source；不单独执行。

UPDATE_LOG="$LOG_DIR/update.log"
UPDATE_TMPDIR="$RUNDIR/update_tmp"
UPDATE_PID="$RUNDIR/update.pid"
UPDATE_LAST_CHECK="$RUNDIR/update_last_check"

# ---------- 版本比较 ----------
# ver_cmp a b → -1(a<b) 0(相等) 1(a>b)。
# 规则：去前导 v 与构建元数据（+后缀、数字开头的 - 后缀）后按 . 拆段，数字段补 0 按数值比（1.0 == 1.0.0）；
# 字母开头的 - 后缀是预发布（beta < 正式版，点分逐段比且数字标识按数值：beta.10 > beta.9）。
# awk 实现（busybox awk 可用）。
UPDATE_VER_AWK='
function split_ver(v, arr,   s, parts, i, j, n, isnum, p) {
	s = v
	sub(/^[vV]/, "", s)
	# + 及其后是构建元数据，剥离（v1.0.0+build.123 == 1.0.0；不剥会吞掉最后一个数字段）
	sub(/\+.*/, "", s)
	# 数字开头的 - 后缀是构建元数据（git hash/发布号），拆段前剥掉：2.6.4-8428a89d == 2.6.4
	sub(/-[0-9][0-9A-Za-z]*$/, "", s)
	n = split(s, parts, ".")
	isnum = 1
	arr["pre"] = ""
	for (i = 1; i <= n; i++) {
		if (parts[i] !~ /^[0-9]+$/) { isnum = 0; break }
	}
	if (isnum) {
		for (i = 1; i <= n; i++) arr[i] = parts[i] + 0
	} else {
		for (i = 1; i <= n; i++) {
			if (parts[i] ~ /^[0-9]+$/) { arr[i] = parts[i] + 0; continue }
			p = parts[i]
			for (j = i + 1; j <= n; j++) p = p "." parts[j]
			# 剥掉并进来的数字前缀（0-beta → beta），字母开头才是预发布，数字开头是构建元数据
			sub(/^[0-9-]+/, "", p)
			if (p !~ /^[A-Za-z]/) { p = "" }
			arr["pre"] = p
			break
		}
	}
	return n
}
function vcmp(a, b,   an, bn, i, x, y) {
	an = split_ver(a, A)
	bn = split_ver(b, B)
	for (i = 1; i <= an || i <= bn; i++) {
		x = (i <= an) ? A[i] + 0 : 0
		y = (i <= bn) ? B[i] + 0 : 0
		if (x < y) return -1
		if (x > y) return 1
	}
	if (A["pre"] == "" && B["pre"] == "") return 0
	if (A["pre"] == "") return 1
	if (B["pre"] == "") return -1
	# 预发布点分逐段比（semver 标识符规则）：数字段按数值且低于字母段，beta.10 > beta.9
	return precmp(A["pre"], B["pre"])
}
function precmp(a, b,   pa, pb, i, na, nb, x, y, xn, yn) {
	na = split(a, pa, ".")
	nb = split(b, pb, ".")
	for (i = 1; i <= na || i <= nb; i++) {
		x = (i <= na) ? pa[i] : ""
		y = (i <= nb) ? pb[i] : ""
		if (x == "" && y == "") return 0
		if (x == "") return -1
		if (y == "") return 1
		xn = (x ~ /^[0-9]+$/) ? 1 : 0
		yn = (y ~ /^[0-9]+$/) ? 1 : 0
		if (xn != yn) return (xn > yn) ? -1 : 1
		if (xn) { if (x + 0 < y + 0) return -1; if (x + 0 > y + 0) return 1 }
		if (x < y) return -1
		if (x > y) return 1
	}
	return 0
}
BEGIN { print vcmp(a, b) }'

ver_cmp() {
	awk -v a="$1" -v b="$2" "$UPDATE_VER_AWK"
}

# GitHub API assets 解析状态机（喂 JSON 文本，吐 name|digest|size 行）。
# 只认裸 `{`/`]` 行定界：GitHub 会在 name 与 digest 之间嵌 uploader 等对象，
# 任意含 { 的行都重置会把每个资产全部丢掉，故锚定整行；digest 为 null（老资产）跳过该资产。
UPDATE_ASSETS_AWK='
/"assets"[[:space:]]*:[[:space:]]*\[/ { ia = 1; next }
ia && /^[[:space:]]*\][[:space:]]*,?[[:space:]]*$/ { ia = 0 }
ia {
	l = $0
	if (l ~ /^[[:space:]]*\{[[:space:]]*,?[[:space:]]*$/) { cur = ""; cursize = "" }
	if (l ~ /"name"[[:space:]]*:/) {
		sub(/.*"name"[[:space:]]*:[[:space:]]*"/, "", l)
		sub(/".*/, "", l)
		cur = l
	} else if (l ~ /"size"[[:space:]]*:/) {
		sub(/.*"size"[[:space:]]*:[[:space:]]*/, "", l)
		sub(/[^0-9].*/, "", l)
		cursize = l
	} else if (l ~ /"digest"[[:space:]]*:/) {
		# 只接受 "sha256:..." 带引号形态；digest: null（老资产）直接放弃配对，防止串到下一资产
		if (l ~ /"digest"[[:space:]]*:[[:space:]]*"sha256:[^"]*"/) {
			sub(/.*"digest"[[:space:]]*:[[:space:]]*"sha256:/, "", l)
			sub(/".*/, "", l)
			if (cur != "") { print cur "|" l "|" cursize; cur = ""; cursize = "" }
		} else {
			cur = ""
		}
	}
}'

# ---------- 代理与 URL ----------
# 代理前缀来自 setting.conf 的 update_proxy_prefix（留空=直连）；末尾无 / 自动补（拼接时依赖）。
update_proxy_prefix() {
	local p
	p=$(setting_file_get update_proxy_prefix 2>/dev/null)
	case "$p" in
	'') return 0 ;;
	*/) printf '%s\n' "$p" ;;
	*) printf '%s\n' "$p/" ;;
	esac
}

# release 元信息 API：一次请求取回 tag 与资产列表（含 sha256 digest）。
update_api_url() {
	local repo=$1 prefix
	prefix=$(update_proxy_prefix)
	printf '%s\n' "${prefix}https://api.github.com/repos/${repo}/releases/latest"
}

# 资产下载地址：自己拼 release 下载路径（便于统一套代理前缀）。
update_download_url() {
	local repo=$1 tag=$2 asset=$3 prefix
	prefix=$(update_proxy_prefix)
	printf '%s\n' "${prefix}https://github.com/${repo}/releases/download/${tag}/${asset}"
}

# 资产模板占位替换：{ver}=去前导 v 的版本号，{tag}=完整 tag。
# awk index 逐个替换，不用 sed——tag 含 & 或 / 会破坏 sed 的 s/// 语义。
update_resolve_asset() {
	local tpl=$1 tag=$2 ver out
	ver=${tag#v}
	out=$(awk -v t="$tpl" -v v="$ver" -v g="$tag" 'BEGIN {
		while ((i = index(t, "{ver}")) > 0) t = substr(t, 1, i - 1) v substr(t, i + 5)
		while ((i = index(t, "{tag}")) > 0) t = substr(t, 1, i - 1) g substr(t, i + 5)
		print t
	}')
	printf '%s\n' "$out"
}

# ---------- busybox 依赖 ----------
# 找含 wget 的 busybox（无 httpd 也可用）。
update_find_busybox() {
	local b
	for b in "$SVCHUB_BUSYBOX" "$(command -v busybox 2>/dev/null)" \
		/data/adb/ksu/bin/busybox /data/adb/magisk/busybox /data/adb/ap/bin/busybox; do
		[ -n "$b" ] && [ -x "$b" ] && "$b" wget --help 2>&1 | grep -q '\-O' && {
			printf '%s\n' "$b"
			return 0
		}
	done
	return 1
}

# 找 sha256sum（系统优先，busybox 兜底）。输出 "路径 sha256sum" 或内置名，调用方按词展开。
update_find_sha256() {
	local b
	if command -v sha256sum >/dev/null 2>&1; then
		printf 'sha256sum\n'
		return 0
	fi
	b=$(update_find_busybox) || return 1
	[ -x "$b" ] || return 1
	"$b" sha256sum --help >/dev/null 2>&1 || return 1
	printf '%s\n' "$b sha256sum"
}

# 下载：$1=URL $2=目标文件 $3=curl 最长秒数（可空默认 300；探测小 JSON 用短超时防黑洞连接拖死检查）。
# curl 优先（设备上一般无 curl，走 busybox wget）；HTTP 4xx/5xx 不重试（资产不存在属配置错误），
# 只有网络层失败才换 wget 再试一次，避免把「404 资产不存在」误报成网络故障。
update_wget() {
	local url=$1 dest=$2 maxtime=${3:-300} bb code
	[ -n "$url" ] && [ -n "$dest" ] || return 1
	if command -v curl >/dev/null 2>&1; then
		code=$(curl -fsSL --max-time "$maxtime" -o "$dest" -w '%{http_code}' "$url" 2>/dev/null)
		if [ "$code" = "200" ]; then
			return 0
		fi
		# 4xx/5xx：服务端明确拒绝，换 wget 也没用
		case "$code" in
		4*|5*) rm -f "$dest"; return 1 ;;
		esac
	fi
	bb=$(update_find_busybox) || { rm -f "$dest"; return 1; }
	"$bb" wget -q -O "$dest" "$url" >/dev/null 2>&1 || { rm -f "$dest"; return 1; }
	return 0
}

# ---------- 版本探测 ----------
# 探测仓库最新 release：成功时写 UPDATE_LATEST_TAG 与 UPDATE_ASSETS（每行 name|digest|size），返回 0。
# 双通道：代理前缀优先，失败退直连；单通道 curl 限时 120s（黑洞连接最长拖 4 分钟会拖死检查）。
update_fetch_latest() {
	local repo=$1 tmp prefix url1 url2 urls url
	UPDATE_LATEST_TAG=""
	UPDATE_ASSETS=""
	[ -n "$repo" ] || return 1
	mkdir -p "$UPDATE_TMPDIR" 2>/dev/null || return 1
	tmp="$UPDATE_TMPDIR/api.json"
	# 探测双通道：代理前缀优先，失败退直连（代理时好时坏、直连可用的网络都能覆盖）
	prefix=$(update_proxy_prefix)
	url1="${prefix}https://api.github.com/repos/${repo}/releases/latest"
	url2="https://api.github.com/repos/${repo}/releases/latest"
	urls="$url1"
	[ -n "$url2" ] && [ "$url2" != "$url1" ] && urls="$urls
$url2"
	for url in $urls; do
		rm -f "$tmp"
		update_wget "$url" "$tmp" 120 || continue
		[ -s "$tmp" ] || continue
		UPDATE_LATEST_TAG=$(awk '
			/"tag_name"[[:space:]]*:/ {
				l = $0
				sub(/.*"tag_name"[[:space:]]*:[[:space:]]*"/, "", l)
				sub(/".*/, "", l)
				print l
				exit
			}' "$tmp" 2>/dev/null)
		UPDATE_ASSETS=$(awk "$UPDATE_ASSETS_AWK" "$tmp" 2>/dev/null)
		# 代理偶发返回 200 错误页或截断响应：tag 或资产列表解析不出都视为失败，退下一通道
		[ -n "$UPDATE_LATEST_TAG" ] && [ -n "$UPDATE_ASSETS" ] && { rm -f "$tmp"; return 0; }
	done
	rm -f "$tmp"
	return 1
}

# 从资产映射取 sha256（$1=映射 name|digest|size $2=资产名）；无 digest 输出空。
update_asset_digest() {
	local map=$1 name=$2
	printf '%s\n' "$map" | awk -F'|' -v n="$name" '$1 == n { print $2; exit }'
}

# 从资产映射取文件大小（字节；$1=映射 $2=资产名）；无则输出空。
update_asset_size() {
	local map=$1 name=$2
	printf '%s\n' "$map" | awk -F'|' -v n="$name" '$1 == n { print $3; exit }'
}

# 选资产：$1=资产映射 $2=期望名 $3=目标文件 basename。
# 精确命中 → 用；否则在列表里找唯一包含 basename 的项 → 用；仍失败则输出错误与可用列表，返回 1。
update_pick_asset() {
	local map=$1 want=$2 base=$3 hits
	# 精确命中
	if printf '%s\n' "$map" | awk -F'|' -v n="$want" '$1 == n { print "yes"; exit }' | grep -q yes; then
		printf '%s\n' "$want"
		return 0
	fi
	# 唯一包含 basename 的项
	hits=$(printf '%s\n' "$map" | awk -F'|' -v b="$base" 'index($1, b) > 0 { print $1 }')
	case "$hits" in
	'') ;;
	*)
		local cnt
		cnt=$(printf '%s\n' "$hits" | grep -c .)
		if [ "$cnt" -eq 1 ]; then
			printf '%s\n' "$hits"
			return 0
		fi
		;;
	esac
	# 失败：可用列表写 stderr（不能污染 stdout 的 JSON 输出）
	printf '%s\n' "$want" >&2
	printf '%s\n' "$map" | awk -F'|' '{ print "  " $1 }' >&2
	return 1
}

# ---------- 校验 ----------
# 文件 sha256：$1=文件；输出 64 位 hex，无则失败。
update_sha256() {
	local f=$1 bin out
	[ -f "$f" ] || return 1
	bin=$(update_find_sha256) || return 1
	out=$($bin "$f" 2>/dev/null | awk '{ print $1 }')
	[ -n "$out" ] || return 1
	printf '%s\n' "$out"
}

# 校验：$1=文件 $2=期望 sha256（空=跳过校验，返回 0）。
update_verify() {
	local f=$1 want=$2 got
	[ -f "$f" ] || return 1
	[ -n "$want" ] || return 0
	got=$(update_sha256 "$f") || return 1
	[ "$got" = "$want" ]
}

# ---------- 解包 ----------
# 归档格式识别：读文件头 6 字节的 magic（不靠扩展名——下载的临时文件名没有正确后缀）。
# 输出 gz|bz2|xz|zip|tar|raw
update_archive_kind() {
	local f=$1 magic
	magic=$(od -An -tx1 -N6 "$f" 2>/dev/null | tr -d ' \n')
	case "$magic" in
	1f8b*) printf 'gz\n' ;;
	425a68*) printf 'bz2\n' ;;
	fd377a585a00*) printf 'xz\n' ;;
	504b0304*|504b0506*|504b0708*) printf 'zip\n' ;;
	*) printf 'tar\n' ;;
	esac
}

# 解包归档到目录：$1=归档 $2=解包目录。返回 0 成功。
update_unpack() {
	local arc=$1 dir=$2 bb kind
	[ -f "$arc" ] || return 1
	rm -rf "$dir" 2>/dev/null
	mkdir -p "$dir" 2>/dev/null || return 1
	bb=$(update_find_busybox 2>/dev/null)
	kind=$(update_archive_kind "$arc")
	case "$kind" in
	zip)
		if [ -n "$bb" ] && "$bb" unzip -o "$arc" -d "$dir" >/dev/null 2>&1; then
			return 0
		fi
		unzip -o "$arc" -d "$dir" >/dev/null 2>&1 && return 0
		return 1
		;;
	gz)
		# gzip 单文件：可能是 .tar.gz（内含 tar）或裸 .gz
		if tar -xzf "$arc" -C "$dir" >/dev/null 2>&1; then
			return 0
		fi
		if [ -n "$bb" ] && "$bb" tar -xzf "$arc" -C "$dir" >/dev/null 2>&1; then
			return 0
		fi
		gzip -dc "$arc" > "$dir/payload" 2>/dev/null && return 0
		[ -n "$bb" ] && "$bb" gzip -dc "$arc" > "$dir/payload" 2>/dev/null && return 0
		return 1
		;;
	bz2)
		tar -xjf "$arc" -C "$dir" >/dev/null 2>&1 && return 0
		[ -n "$bb" ] && "$bb" tar -xjf "$arc" -C "$dir" >/dev/null 2>&1 && return 0
		bzip2 -dc "$arc" > "$dir/payload" 2>/dev/null && return 0
		[ -n "$bb" ] && "$bb" bzip2 -dc "$arc" > "$dir/payload" 2>/dev/null && return 0
		return 1
		;;
	xz)
		tar -xJf "$arc" -C "$dir" >/dev/null 2>&1 && return 0
		[ -n "$bb" ] && "$bb" tar -xJf "$arc" -C "$dir" >/dev/null 2>&1 && return 0
		xz -dc "$arc" > "$dir/payload" 2>/dev/null && return 0
		[ -n "$bb" ] && "$bb" xz -dc "$arc" > "$dir/payload" 2>/dev/null && return 0
		return 1
		;;
	tar)
		# 裸二进制资产（release 不打包）也会落到这里：tar 失败则原样当待装内容
		if tar -xf "$arc" -C "$dir" >/dev/null 2>&1; then
			return 0
		fi
		if [ -n "$bb" ] && "$bb" tar -xf "$arc" -C "$dir" >/dev/null 2>&1; then
			return 0
		fi
		cp -f "$arc" "$dir/payload" 2>/dev/null && return 0
		return 1
		;;
	esac
	return 1
}

# file 模式取待安装文件：$1=解包目录 $2=目标 basename。输出文件路径。
update_pick_file() {
	local dir=$1 want=$2 found
	found=$(find "$dir" -type f -name "$want" 2>/dev/null | head -n 1)
	if [ -n "$found" ]; then
		printf '%s\n' "$found"
		return 0
	fi
	# 唯一可执行文件
	found=$(find "$dir" -type f -perm -u+x 2>/dev/null | head -n 1)
	if [ -n "$found" ]; then
		printf '%s\n' "$found"
		return 0
	fi
	# 第一个普通文件
	found=$(find "$dir" -type f 2>/dev/null | head -n 1)
	[ -n "$found" ] || return 1
	printf '%s\n' "$found"
}

# dir 模式取待安装内容源：$1=解包目录。输出目录（唯一子目录则取之，否则取解包目录本身）。
update_pick_dir() {
	local dir=$1 p n=0 only=""
	for p in "$dir"/*; do
		[ -e "$p" ] || continue
		n=$((n + 1))
		only=$p
	done
	if [ "$n" -eq 1 ] && [ -d "$only" ]; then
		printf '%s\n' "$only"
		return 0
	fi
	printf '%s\n' "$dir"
}

# file 模式取待装内容：解包 → 按目标 basename 定位（find 递归，demo.zip 内 test/binary 这类嵌套路径
# 直接命中）→ 若取出的文件本身仍是归档（zip 套 tar.gz 的发布形态）就再解一层。
# 注意 update_archive_kind 对未知 magic（裸二进制）兜底返回 tar，故 tar 分支需 tar -tf 验真后再解。
# 内层解包成功但找不到目标时直接失败——外层是归档，装回去等于装垃圾，不回退。
# $1=归档 $2=解包工作目录 $3=目标 basename → 输出待装文件路径。
update_extract_payload() {
	local arc=$1 dir=$2 want=$3 src kind inner src2
	update_unpack "$arc" "$dir" || return 1
	src=$(update_pick_file "$dir" "$want") || return 1
	kind=$(update_archive_kind "$src")
	case "$kind" in
	gz|bz2|xz|zip) : ;;
	tar)
		# 裸二进制的 magic 也兜底成 tar：tar -tf 验真，列不动的就是二进制本身
		tar -tf "$src" >/dev/null 2>&1 || { printf '%s\n' "$src"; return 0; }
		;;
	*) printf '%s\n' "$src"; return 0 ;;
	esac
	inner="$dir/inner"
	if update_unpack "$src" "$inner"; then
		# 内层严格按目标名找：找不到说明外层归档形状不对，宁可失败也不装错文件
		#（pick_file 的「第一个普通文件」兜底会把 inner 里的无关文件当二进制）
		src2=$(find "$inner" -type f -name "$want" 2>/dev/null | head -n 1)
		if [ -n "$src2" ]; then
			printf '%s\n' "$src2"
			return 0
		fi
		return 1
	fi
	# 内层解不动（取出的并非归档，如单文件 .gz）：取出的就是待装内容
	printf '%s\n' "$src"
}

# ---------- 替换 ----------
# 同目录写临时文件再 rename（避免 FUSE 跨目录不原子、避免覆盖运行中的 ELF 报 ETXTBSY）。
update_replace_file() {
	local src=$1 dst=$2 tmp
	[ -f "$src" ] || return 1
	# 首次安装目标父目录可能不存在，先建（规格错误表：首次安装直接写入）
	mkdir -p "$(dirname "$dst")" 2>/dev/null
	tmp="$dst.svchub_new"
	rm -f "$tmp"
	cp -f "$src" "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
	chmod 755 "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
	mv -f "$tmp" "$dst" 2>/dev/null || { rm -f "$tmp"; return 1; }
	return 0
}

# 备份当前文件到同目录 .svchub_bak；目标不存在返回 1（首次安装，无需备份）。
update_backup_file() {
	local dst=$1 bak="$1.svchub_bak"
	[ -f "$dst" ] || return 1
	rm -f "$bak"
	cp -f "$dst" "$bak" 2>/dev/null || return 1
	return 0
}

# 回滚：从 .svchub_bak 还原。
update_rollback_file() {
	local dst=$1 bak="$1.svchub_bak"
	[ -f "$bak" ] || return 1
	# 走同目录 tmp+mv（rename 不触碰运行中 inode），与 update_replace_file 同一原则
	mv -f "$bak" "$dst" 2>/dev/null || return 1
	chmod 755 "$dst" 2>/dev/null
	return 0
}

# 清理备份与临时文件（文件与目录两种备份形态统一处理）。
update_cleanup_backup() {
	local dst=$1
	rm -rf "$dst.svchub_bak"
	rm -f "$dst.svchub_new"
}

# 备份当前目录到 .svchub_bak（dir 模式；cp -Rp 保权限，目标不存在返回 1）。
update_backup_dir() {
	local dst=$1 bak="$1.svchub_bak"
	[ -d "$dst" ] || return 1
	rm -rf "$bak"
	cp -Rp "$dst" "$bak" 2>/dev/null || { rm -rf "$bak"; return 1; }
	return 0
}

# 回滚目录：清掉半覆盖的目标，整份还原备份。
update_rollback_dir() {
	local dst=$1 bak="$1.svchub_bak"
	[ -d "$bak" ] || return 1
	rm -rf "$dst"
	mv "$bak" "$dst" 2>/dev/null || return 1
	return 0
}

# 写回条目版本字段：文件与内存副本同步更新，原行序与其余段不变。
# $1=条目名 $2=段号（7=ins_ver 已装 9=update_ver 检查到的最新） $3=版本（可空=清除）。
update_entry_set_field() {
	local name=$1 seg=$2 ver=$3 tmp="$UPDATE_CONF.tmp.$$"
	[ -n "$name" ] && [ -n "$seg" ] || return 1
	# tag 里的字符超出存储字符集（如 release/1.0 含 /）会让该行下次加载被整行跳过，剥掉非合法字符
	ver=$(printf '%s' "$ver" | tr -cd 'A-Za-z0-9._+-')
	# 内存副本先行：即使文件写入失败，本次调用的输出也已是新值
	if [ -n "$UPDATE_ENTRIES" ]; then
		UPDATE_ENTRIES=$(printf '%s\n' "$UPDATE_ENTRIES" | awk -F'|' -v n="$name" -v sg="$seg" -v v="$ver" '
			BEGIN { OFS = "|" }
			{ if ($1 == n) $sg = v; print }')
	fi
	[ -f "$UPDATE_CONF" ] || return 0
	awk -F'|' -v n="$name" -v sg="$seg" -v v="$ver" 'BEGIN { OFS = "|" }
		$1 == n { $sg = v }
		{ print }' "$UPDATE_CONF" > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
	mv -f "$tmp" "$UPDATE_CONF" 2>/dev/null || { rm -f "$tmp"; return 1; }
	LOAD_CFG_DONE=""
	return 0
}

# 已装版本（第 7 段 ins_ver）：更新成功后写入。
update_set_ins_ver() {
	update_entry_set_field "$1" 7 "$2"
}

# 检查到的最新版本（第 9 段 update_ver）：每次检查后写入，刷新页面不丢。
update_set_update_ver() {
	update_entry_set_field "$1" 9 "$2"
}

# ---------- 本地版本探测 ----------
# 用「目标路径 + 版本查询参数」执行二进制并从输出提取版本号。
# $1=查询参数（如 version / --version / -v；留空=按常见参数逐个探测）
# $2=目标路径（相对 server_dir） $3=原始输出落盘路径（可选，失败排查用）
# 工作目录为 $SERVER_DIR（与服务启动基准一致）。
# 输出提取到的版本号（原样保留，v0.31.0 与 0.31.0 都合法，比较时由 ver_cmp 忽略 v）。
# 各二进制查版本参数不同（version/--version/-v/v），填错的参数只会得到 usage，故逐个试。
UPDATE_VER_PROBES='--version version -v v'

update_ver_probe() {
	local bin=$1 args=$2 rawfile=$3 out ver
	# 在服务目录执行，限时 10 秒防挂死；stderr 一并收（部分程序版本印在 stderr）。
	# timeout 直接作用于二进制（不经 sh 转发）：常驻二进制被杀不留孤儿；参数词切分传递
	if command -v timeout >/dev/null 2>&1; then
		out=$( cd "$SERVER_DIR" 2>/dev/null && timeout 10 "$bin" $args 2>&1 ) || true
	else
		out=$( cd "$SERVER_DIR" 2>/dev/null && "$bin" $args 2>&1 ) || true
	fi
	# 原始输出回传（供失败时记日志）：压成单行并截断
	if [ -n "$rawfile" ]; then
		printf '%s' "$out" | head -n 2 | tr '\n' ' ' | cut -c1-200 > "$rawfile" 2>/dev/null
	fi
	[ -n "$out" ] || return 1
	# 单次 awk 提取：不依赖 grep -o（部分 toybox 不支持），
	# 取第一个不嵌在更长字母数字串里的版本号，v 前缀可有可无。
	ver=$(printf '%s\n' "$out" | awk '
		{
			s = $0
			pos = 1
			while (pos <= length(s)) {
				if (!match(substr(s, pos), /[vV]?[0-9]+\.[0-9]+(\.[0-9]+)?([-+][A-Za-z0-9.]+)?/)) break
				start = pos + RSTART - 1
				len = RLENGTH
				prev = (start > 1) ? substr(s, start - 1, 1) : ""
				# 前一个字符是字母/数字/点时说明是长词的一部分（如 go1.25.0），跳过
				if (prev ~ /[A-Za-z0-9.]/) { pos = start + len; continue }
				print substr(s, start, len)
				exit
			}
		}')
	[ -n "$ver" ] || return 1
	printf '%s\n' "$ver"
}

update_local_version() {
	local args=$1 target=$2 rawfile=$3 bin p out
	[ -n "$target" ] || return 1
	# 目标路径归一化成相对 server_dir 的可执行形式
	case "$target" in
	/*|./*) bin="$target" ;;
	*) bin="./$target" ;;
	esac
	# 用户填的参数优先；没填或没取到再按常见参数逐个探测兜底
	if [ -n "$args" ]; then
		update_ver_probe "$bin" "$args" "$rawfile" && return 0
	fi
	for p in $UPDATE_VER_PROBES; do
		[ "$p" = "$args" ] && continue
		update_ver_probe "$bin" "$p" "$rawfile" && return 0
	done
	return 1
}

# 实测本地版本并回写 ins_ver（第 7 段）：vercmd 非空按参数（失败再逐个兜底），
# 留空且不知道版本时也逐个兜底；目标二进制不存在/不可执行时跳过，返回传入的 ins。
# $1=条目名 $2=vercmd $3=目标路径 $4=已装版本旧值 → 输出实测/回退后的版本（写 update.log）。
update_refresh_ins_ver() {
	local name=$1 vercmd=$2 target=$3 ins=$4 cur rawf="$UPDATE_TMPDIR/.verraw.$$"
	cur=$ins
	if { [ -n "$vercmd" ] || [ -z "$cur" ]; } && [ -x "$SERVER_DIR/$target" ]; then
		if cur=$(update_local_version "$vercmd" "$target" "$rawf"); then
			[ "$cur" = "$ins" ] || update_set_ins_ver "$name" "$cur"
		else
			update_log "[$name] $(ui_msg '版本命令未取到版本号（输出：%s）' "$(cat "$rawf" 2>/dev/null || echo '<空>')")"
			cur=$ins
		fi
		rm -f "$rawf"
	fi
	printf '%s\n' "$cur"
}

# ---------- 日志 ----------
update_log() {
	local msg=$1
	[ -n "$msg" ] || return 0
	echo "[$(date '+%F %T')] $msg" >> "$UPDATE_LOG"
}

# ---------- 下载（带进度） ----------
# 后台下载并每 2 秒汇报一次进度（与日志弹窗 3 秒刷新节奏衔接）。
# $1=URL $2=目标文件 $3=条目名 $4=预期字节数（release API 的 size；空/0 则不报百分比只等结束）。
# 进度按 5% 步进记日志，避免刷屏；返回下载命令的退出码。
update_download() {
	local url=$1 dest=$2 name=$3 total=$4 wp last=0 cur pct mb tmb
	update_wget "$url" "$dest" &
	wp=$!
	while kill -0 "$wp" 2>/dev/null; do
		sleep 2
		# 目标文件未创建时 wc 的 < 重定向报错会穿透 $() 污染 update.log，先确认存在
		[ -f "$dest" ] || continue
		cur=$(wc -c < "$dest" 2>/dev/null | tr -d ' ')
		[ -n "$cur" ] || cur=0
		case "$total" in
		''|*[!0-9]*|0) continue ;;
		esac
		pct=$((cur * 100 / total))
		[ $((pct - last)) -ge 5 ] || continue
		mb=$(awk -v b="$cur" 'BEGIN { printf "%.1f", b / 1048576 }')
		tmb=$(awk -v b="$total" 'BEGIN { printf "%.1f", b / 1048576 }')
		update_log "[$name] $(ui_msg '下载进度 %s%（%s/%s MB）' "$pct" "$mb" "$tmb")"
		last=$pct
	done
	wait "$wp"
}

