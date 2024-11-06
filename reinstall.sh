#!/usr/bin/env bash
# nixos 默认的配置不会生成 /bin/bash
# shellcheck disable=SC2086

set -eE
confhome=https://raw.githubusercontent.com/cuicanmx/reinstall/main
confhome_cn=https://jihulab.com/bin456789/reinstall/-/raw/main
# confhome_cn=https://mirror.ghproxy.com/https://raw.githubusercontent.com/bin456789/reinstall/main

# 用于判断 reinstall.sh 和 trans.sh 是否兼容
SCRIPT_VERSION=4BACD833-A585-23BA-6CBB-9AA4E08E0001

# https://www.gnu.org/software/gettext/manual/html_node/The-LANGUAGE-variable.html
export LC_ALL=C

# 处理部分用户用 su 切换成 root 导致环境变量没 sbin 目录
# 不要漏了最后的 $PATH，否则会找不到 windows 系统程序例如 diskpart
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH

# 记录日志
exec > >(exec tee /reinstall.log) 2>&1
THIS_SCRIPT=$(readlink -f "$0")
trap 'trap_err $LINENO $?' ERR

trap_err() {
    line_no=$1
    ret_no=$2

    error "Line $line_no return $ret_no"
    sed -n "$line_no"p "$THIS_SCRIPT"
}

usage_and_exit() {
    if is_in_windows; then
        reinstall____=' reinstall.bat'
    else
        reinstall____='./reinstall.sh'
    fi
    cat <<EOF
Usage: $reinstall____ centos      9
                      anolis      7|8
                      alma        8|9
                      rocky       8|9
                      redhat      8|9   --img='http://xxx.com/xxx.qcow2'
                      opencloudos 8|9
                      oracle      7|8|9
                      fedora      39|40
                      nixos       24.05
                      debian      9|10|11|12
                      openeuler   20.03|22.03|24.03
                      alpine      3.17|3.18|3.19|3.20
                      opensuse    15.5|15.6|tumbleweed
                      ubuntu      16.04|18.04|20.04|22.04|24.04 [--minimal]
                      kali
                      arch
                      gentoo
                      dd          --img='http://xxx.com/xxx.raw'  (supports raw vhd gzip xz)
                      windows     --image-name='windows xxx yyy'  --lang=xx-yy
                      windows     --image-name='windows xxx yyy'  --iso='http://xxx.com/xxx.iso'
                      netboot.xyz

Manual: https://github.com/bin456789/reinstall

EOF
    exit 1
}

info() {
    upper=$(to_upper <<<"$@")
    echo_color_text '\e[32m' "***** $upper *****"
}

warn() {
    echo_color_text '\e[33m' "Warning: $*"
}

error() {
    echo_color_text '\e[31m' "Error: $*"
}

echo_color_text() {
    color="$1"
    shift
    plain="\e[0m"
    echo -e "$color$*$plain"
}

error_and_exit() {
    error "$@"
    exit 1
}

curl() {
    # 添加 -f, --fail，不然 404 退出码也为0
    # 32位 cygwin 已停止更新，证书可能有问题，先添加 --insecure
    # centos 7 curl 不支持 --retry-connrefused --retry-all-errors
    # 因此手动 retry
    grep -o 'http[^ ]*' <<<"$@" >&2
    for i in $(seq 5); do
        if command curl --insecure --connect-timeout 10 -f "$@"; then
            return
        else
            ret=$?
            # 403 404 错误，或者达到重试次数
            if [ $ret -eq 22 ] || [ $i -eq 5 ]; then
                return $ret
            fi
            sleep 1
        fi
    done
}

is_in_china() {
    if [ -z "$_loc" ]; then
        # 部分地区 www.cloudflare.com 被墙
        _loc=$(curl -L http://dash.cloudflare.com/cdn-cgi/trace | grep '^loc=' | cut -d= -f2)
        if [ -z "$_loc" ]; then
            error_and_exit "Can not get location."
        fi
    fi
    [ "$_loc" = CN ]
}

is_in_windows() {
    [ "$(uname -o)" = Cygwin ] || [ "$(uname -o)" = Msys ]
}

is_in_alpine() {
    [ -f /etc/alpine-release ]
}

is_use_cloud_image() {
    [ -n "$cloud_image" ] && [ "$cloud_image" = 1 ]
}

is_force_use_installer() {
    [ -n "$installer" ] && [ "$installer" = 1 ]
}

is_use_dd() {
    [ "$distro" = dd ]
}

is_boot_in_separate_partition() {
    mount | grep -q ' on /boot type '
}

is_os_in_btrfs() {
    mount | grep -q ' on / type btrfs '
}

is_os_in_subvol() {
    subvol=$(awk '($2=="/") { print $i }' /proc/mounts | grep -o 'subvol=[^ ]*' | cut -d= -f2)
    [ "$subvol" != / ]
}

get_os_part() {
    awk '($2=="/") { print $1 }' /proc/mounts
}

cp_to_btrfs_root() {
    mount_dir=$tmp/reinstall-btrfs-root
    if ! grep -q $mount_dir /proc/mounts; then
        mkdir -p $mount_dir
        mount "$(get_os_part)" $mount_dir -t btrfs -o subvol=/
    fi
    cp -rf "$@" $tmp/reinstall-btrfs-root
}

is_host_has_ipv4_and_ipv6() {
    host=$1

    install_pkg dig
    # dig会显示cname结果，cname结果以.结尾，grep -v '\.$' 用于去除 cname 结果
    res=$(dig +short $host A $host AAAA | grep -v '\.$')
    # 有.表示有ipv4地址，有:表示有ipv6地址
    grep -q \. <<<$res && grep -q : <<<$res
}

is_netboot_xyz() {
    [ "$distro" = netboot.xyz ]
}

is_alpine_live() {
    [ "$distro" = alpine ] && [ "$hold" = 1 ]
}

is_have_initrd() {
    ! is_netboot_xyz
}

is_use_firmware() {
    # shellcheck disable=SC2154
    [ "$nextos_distro" = debian ] && ! is_virt
}

get_host_by_url() {
    cut -d/ -f3 <<<$1
}

get_function() {
    declare -f "$1"
}

get_function_content() {
    declare -f "$1" | sed '1d;2d;$d'
}

insert_into_file() {
    file=$1
    location=$2
    regex_to_find=$3

    line_num=$(grep -E -n "$regex_to_find" "$file" | cut -d: -f1)

    found_count=$(echo "$line_num" | wc -l)
    if [ ! "$found_count" -eq 1 ]; then
        return 1
    fi

    case "$location" in
    before) line_num=$((line_num - 1)) ;;
    after) ;;
    *) return 1 ;;
    esac

    sed -i "${line_num}r /dev/stdin" "$file"
}

test_url() {
    test_url_real false "$@"
}

test_url_grace() {
    test_url_real true "$@"
}

test_url_real() {
    grace=$1
    url=$2
    expect_types=$3
    var_to_eval=$4
    info test url

    failed() {
        $grace && return 1
        error_and_exit "$@"
    }

    tmp_file=$tmp/img-test

    # TODO: 好像无法识别 nixos 官方源的跳转
    # 有的服务器不支持 range，curl会下载整个文件
    # 所以用 head 限制 1M
    # 过滤 curl 23 错误（head 限制了大小）
    # 也可用 ulimit -f 但好像 cygwin 不支持
    # ${PIPESTATUS[n]} 表示第n个管道的返回值
    echo $url
    for i in $(seq 5 -1 0); do
        if command curl --insecure --connect-timeout 10 -Lfr 0-1048575 "$url" \
            1> >(exec head -c 1048576 >$tmp_file) \
            2> >(exec grep -v 'curl: (23)' >&2); then
            break
        else
            ret=$?
            msg="$url not accessible"
            case $ret in
            22) failed "$msg" ;;                # 403 404
            23) break ;;                        # 限制了空间
            *) [ $i -eq 0 ] && failed "$msg" ;; # 其他错误
            esac
            sleep 1
        fi
    done

    # 如果要检查文件类型
    if [ -n "$expect_types" ]; then
        install_pkg file
        real_type=$(file_enhanced $tmp_file)
        echo "$real_type"

        # 期待值没有.表示要只需判断外侧
        if ! grep -Fq . <<<"$expect_types"; then
            real_type=$(echo "$real_type" | cut -d. -f2-)
        fi

        # 检查
        if ! grep -Foq "|$real_type|" <<<"|$expect_types|"; then
            failed "$url
expected: $expect_types
actually: $real_type"
        fi
    fi

    # 如果要设置变量
    if [ -n "$var_to_eval" ]; then
        IFS=. read -r "${var_to_eval?}" "${var_to_eval}_warp" <<<"$real_type"
    fi
}

fix_file_type() {
    # gzip的mime有很多种写法
    # centos7中显示为 x-gzip，在其他系统中显示为 gzip，可能还有其他
    # 所以不用mime判断
    # https://www.digipres.org/formats/sources/tika/formats/#application/gzip

    # --extension 不靠谱
    # file -b /reinstall-tmp/img-test --mime-type
    # application/x-qemu-disk
    # file -b /reinstall-tmp/img-test --extension
    # ???

    # 有些 file 版本输出的是 # ISO 9660 CD-ROM filesystem data ，要去掉开头的井号

    # 下面两种都是 raw
    # DOS/MBR boot sector
    # x86 boot sector; partition 1: ...

    sed 's/^# //' | awk '{print $1}' | to_lower |
        sed -e 's,dos/mbr,raw,' -e 's,x86,raw,'
}

file_enhanced() {
    local file=$1
    local outside inside

    outside=$(file -b $file | fix_file_type)

    if [ "$outside" = "xz" ] || [ "$outside" = "gzip" ]; then
        # 要安装 xz 或者 gzip，不然会报错
        # ERROR:[xz: Wait failed, No child process]
        install_pkg "$outside"

        # 加 if 是为了避免以下情况（外面是xz，但是识别不到里面的东西，即使装了xz）,
        # 即使 file 报错返回值也是 0
        # [root@localhost ~]# file -bZ /reinstall-tmp/img-test
        # ERROR:[xz: Unexpected end of input]
        if inside="$(file -bZ $file | fix_file_type)" && ! grep -iq "^Error" <<<"$inside"; then
            echo "$inside.$outside"
            return
        fi
    fi
    echo "$outside"
}

add_community_repo_for_alpine() {
    # 先检查原来的repo是不是egde
    if grep -q '^http.*/edge/main$' /etc/apk/repositories; then
        alpine_ver=edge
    else
        alpine_ver=v$(cut -d. -f1,2 </etc/alpine-release)
    fi

    if ! grep -q "^http.*/$alpine_ver/community$" /etc/apk/repositories; then
        mirror=$(grep '^http.*/main$' /etc/apk/repositories | sed 's,/[^/]*/main$,,' | head -1)
        echo $mirror/$alpine_ver/community >>/etc/apk/repositories
    fi
}

assert_not_in_container() {
    _error_and_exit() {
        error_and_exit "Not Supported OS in Container.\nPlease use https://github.com/LloydAsp/OsMutation"
    }

    is_in_windows && return

    if is_have_cmd systemd-detect-virt; then
        if systemd-detect-virt -qc; then
            _error_and_exit
        fi
    else
        if [ -d /proc/vz ] || grep -q container=lxc /proc/1/environ; then
            _error_and_exit
        fi
    fi
}

is_virt() {
    if [ -z "$_is_virt" ]; then
        if is_in_windows; then
            # https://github.com/systemd/systemd/blob/main/src/basic/virt.c
            # https://sources.debian.org/src/hw-detect/1.159/hw-detect.finish-install.d/08hw-detect/
            vmstr='VMware|Virtual|Virtualization|VirtualBox|VMW|Hyper-V|Bochs|QEMU|KVM|OpenStack|KubeVirt|innotek|Xen|Parallels|BHYVE'
            for name in ComputerSystem BIOS BaseBoard; do
                if wmic $name get /format:list | grep -Eiw $vmstr; then
                    _is_virt=true
                    break
                fi
            done

            # 没有风扇和温度信息，大概是虚拟机
            if [ -z "$_is_virt" ] &&
                ! wmic /namespace:'\\root\cimv2' PATH Win32_Fan 2>/dev/null | grep -q Name &&
                ! wmic /namespace:'\\root\wmi' PATH MSAcpi_ThermalZoneTemperature 2>/dev/null | grep -q Name; then
                _is_virt=true
            fi
        else
            # aws t4g debian 11
            # systemd-detect-virt: 为 none，即使装了dmidecode
            # virt-what: 未装 deidecode时结果为空，装了deidecode后结果为aws
            # 所以综合两个命令的结果来判断
            if is_have_cmd systemd-detect-virt && systemd-detect-virt -v; then
                _is_virt=true
            fi

            if [ -z "$_is_virt" ]; then
                # debian 安装 virt-what 不会自动安装 dmidecode，因此结果有误
                install_pkg dmidecode virt-what
                # virt-what 返回值始终是0，所以用是否有输出作为判断
                if [ -n "$(virt-what)" ]; then
                    _is_virt=true
                fi
            fi
        fi

        if [ -z "$_is_virt" ]; then
            _is_virt=false
        fi
        echo "vm: $_is_virt"
    fi
    $_is_virt
}

# sr-latn-rs 到 sr-latn
en_us() {
    echo "$lang" | awk -F- '{print $1"-"$2}'

    # zh-hk 可回落到 zh-tw
    if [ "$lang" = zh-hk ]; then
        echo zh-tw
    fi
}

# fr-ca 到 ca
us() {
    # 葡萄牙准确对应 pp
    if [ "$lang" = pt-pt ]; then
        echo pp
        return
    fi
    # 巴西准确对应 pt
    if [ "$lang" = pt-br ]; then
        echo pt
        return
    fi

    echo "$lang" | awk -F- '{print $2}'

    # hk 额外回落到 tw
    if [ "$lang" = zh-hk ]; then
        echo tw
    fi
}

# fr-ca 到 fr-fr
en_en() {
    echo "$lang" | awk -F- '{print $1"-"$1}'

    # en-gb 额外回落到 en-us
    if [ "$lang" = en-gb ]; then
        echo en-us
    fi
}

# fr-ca 到 fr
en() {
    # 巴西/葡萄牙回落到葡萄牙语
    if [ "$lang" = pt-br ] || [ "$lang" = pt-pt ]; then
        echo "pp"
        return
    fi

    echo "$lang" | awk -F- '{print $1}'
}

english() {
    case "$lang" in
    ar-sa) echo Arabic ;;
    bg-bg) echo Bulgarian ;;
    cs-cz) echo Czech ;;
    da-dk) echo Danish ;;
    de-de) echo German ;;
    el-gr) echo Greek ;;
    en-gb) echo Eng_Intl ;;
    en-us) echo English ;;
    es-es) echo Spanish ;;
    es-mx) echo Spanish_Latam ;;
    et-ee) echo Estonian ;;
    fi-fi) echo Finnish ;;
    fr-ca) echo FrenchCanadian ;;
    fr-fr) echo French ;;
    he-il) echo Hebrew ;;
    hr-hr) echo Croatian ;;
    hu-hu) echo Hungarian ;;
    it-it) echo Italian ;;
    ja-jp) echo Japanese ;;
    ko-kr) echo Korean ;;
    lt-lt) echo Lithuanian ;;
    lv-lv) echo Latvian ;;
    nb-no) echo Norwegian ;;
    nl-nl) echo Dutch ;;
    pl-pl) echo Polish ;;
    pt-pt) echo Portuguese ;;
    pt-br) echo Brazilian ;;
    ro-ro) echo Romanian ;;
    ru-ru) echo Russian ;;
    sk-sk) echo Slovak ;;
    sl-si) echo Slovenian ;;
    sr-latn | sr-latn-rs) echo Serbian_Latin ;;
    sv-se) echo Swedish ;;
    th-th) echo Thai ;;
    tr-tr) echo Turkish ;;
    uk-ua) echo Ukrainian ;;
    zh-cn) echo ChnSimp ;;
    zh-hk | zh-tw) echo ChnTrad ;;
    esac
}

parse_windows_image_name() {
    set -- $image_name

    if ! [ "$1" = windows ]; then
        return 1
    fi
    shift

    if [ "$1" = server ]; then
        server=server
        shift
    fi

    version=$1
    shift

    if [ "$1" = r2 ]; then
        version+=" r2"
        shift
    fi

    edition=
    while [ $# -gt 0 ]; do
        case "$1" in
        # windows 10 enterprise n ltsc 2021
        k | n | kn) ;;
        *)
            if [ -n "$edition" ]; then
                edition+=" "
            fi
            edition+="$1"
            ;;
        esac
        shift
    done
}

is_have_arm_version() {
    case "$version" in
    10)
        case "$edition" in
        pro | education | enterprise | 'pro education' | 'pro for workstations') return ;;
        'iot enterprise') return ;;
        'enterprise ltsc 2021' | 'iot enterprise ltsc 2021') return ;;
        esac
        ;;
    11)
        case "$edition" in
        pro | education | enterprise | 'pro education' | 'pro for workstations') return ;;
        'iot enterprise' | 'iot enterprise subscription') return ;;
        'enterprise ltsc 2024' | 'iot enterprise ltsc 2024' | 'iot enterprise ltsc 2024 subscription') return ;;
        esac
        ;;
    esac
    return 1
}

find_windows_iso() {
    parse_windows_image_name || error_and_exit "--image-name wrong: $image_name"
    if ! [ "$version" = 8.1 ] && [ -z "$edition" ]; then
        error_and_exit "Edition is not set."
    fi
    if [ "$basearch" = 'aarch64' ] && ! is_have_arm_version; then
        error_and_exit "No ARM iso for this Windows Version."
    fi

    if [ -z "$lang" ]; then
        lang=en-us
    fi
    langs="$lang $(en_us) $(us) $(en_en) $(en)"
    langs=$(echo "$langs" | xargs -n 1 | awk '!seen[$0]++')
    full_lang=$(english)

    case "$basearch" in
    x86_64) arch_win=x64 ;;
    aarch64) arch_win=arm64 ;;
    esac

    get_windows_iso_links
    get_windows_iso_link
}

get_windows_iso_links() {
    get_label_msdn() {
        if [ -n "$server" ]; then
            case "$version" in
            2008 | '2008 r2')
                case "$edition" in
                serverweb | serverwebcore) echo _ ;;
                serverstandard | serverstandardcore) echo _ ;;
                serverenterprise | serverenterprisecore) echo _ ;;
                serverdatacenter | serverdatacentercore) echo _ ;;
                esac
                ;;
            '2012 r2' | \
                2016 | 2019 | 2022 | 2025)
                case "$edition" in
                serverstandard | serverstandardcore) echo _ ;;
                serverdatacenter | serverdatacentercore) echo _ ;;
                esac
                ;;
            esac
        else
            case "$version" in
            vista)
                case "$edition" in
                starter)
                    case "$arch_win" in
                    x86) echo _ ;;
                    esac
                    ;;
                homebasic | homepremium | business | ultimate) echo _ ;;
                enterprise) echo enterprise ;;
                esac
                ;;
            7)
                case "$edition" in
                starter)
                    case "$arch_win" in
                    x86) echo ultimate ;;
                    esac
                    ;;
                professional) echo professional ;;
                homebasic | homepremium | ultimate) echo ultimate ;;
                enterprise) echo enterprise ;;
                esac
                ;;
            8.1)
                case "$edition" in
                '') echo _ ;;
                pro) echo pro ;;
                enterprise) echo enterprise ;;
                esac
                ;;
            10)
                case "$edition" in
                home | 'home single language') echo consumer ;;
                pro | education | enterprise | 'pro education' | 'pro for workstations') echo business ;;
                # iot
                'iot enterprise') echo 'iot enterprise' ;;
                # iot ltsc
                'iot enterprise ltsc 2019' | 'iot enterprise ltsc 2021') echo "$edition" ;;
                # ltsc
                'enterprise 2015 ltsb' | 'enterprise 2016 ltsb' | 'enterprise ltsc 2019') echo "$edition" ;;
                'enterprise ltsc 2021')
                    # arm64 的 enterprise ltsc 2021 要下载 iot enterprise ltsc 2021 iso
                    case "$arch_win" in
                    arm64) echo 'iot enterprise ltsc 2021' ;;
                    x86 | x64) echo 'enterprise ltsc 2021' ;;
                    esac
                    ;;
                esac
                ;;
            11)
                case "$edition" in
                home | 'home single language') echo consumer ;;
                pro | education | enterprise | 'pro education' | 'pro for workstations') echo business ;;
                # iot
                'iot enterprise' | 'iot enterprise subscription') echo 'iot enterprise' ;;
                # iot ltsc
                'iot enterprise ltsc 2024' | 'iot enterprise ltsc 2024 subscription') echo 'iot enterprise ltsc 2024' ;;
                # ltsc
                'enterprise ltsc 2024')
                    # arm64 的 enterprise ltsc 2024 要下载 iot enterprise ltsc 2024 iso
                    case "$arch_win" in
                    arm64) echo 'iot enterprise ltsc 2024' ;;
                    x64) echo 'enterprise ltsc 2024' ;;
                    esac
                    ;;
                esac
                ;;
            esac
        fi
    }

    get_label_vlsc() {
        case "$version" in
        10 | 11)
            case "$edition" in
            pro | education | enterprise | 'pro education' | 'pro for workstations') echo pro ;;
            esac
            ;;
        esac
    }

    get_page() {
        if [ "$arch_win" = arm64 ]; then
            echo arm
        elif is_ltsc; then
            echo ltsc
        elif [ "$server" = 'server' ]; then
            echo server
        else
            case "$version" in
            vista | 7 | 8.1 | 10 | 11)
                echo "$version"
                ;;
            esac
        fi
    }

    is_ltsc() {
        grep -Ewq 'ltsb|ltsc' <<<"$edition"
    }

    # 部分 bash 不支持 $() 里面嵌套case，所以定义成函数
    label_msdn=$(get_label_msdn)
    label_vlsc=$(get_label_vlsc)
    page=$(get_page)

    page_url=https://massgrave.dev/windows_${page}_links.html

    info "Find windows iso"
    echo "Version:    $version"
    echo "Edition:    $edition"
    echo "Label msdn: $label_msdn"
    echo "Label vlsc: $label_vlsc"
    echo "List:       $page_url"
    echo

    if [ -z "$page" ] || { [ -z "$label_msdn" ] && [ -z "$label_vlsc" ]; }; then
        error_and_exit "Not support find this iso. Check --image-name or set --iso manually."
    fi

    curl -L "$page_url" | grep -ioP 'https://.*?.iso' >$tmp/win.list

    # 如果不是 ltsc ，应该先去除 ltsc 链接，否则最终链接有 ltsc 的
    # 例如查找 windows 10 iot enterprise，会得到
    # en-us_windows_10_iot_enterprise_ltsc_2021_arm64_dvd_e8d4fc46.iso
    # en-us_windows_10_iot_enterprise_version_22h2_arm64_dvd_39566b6b.iso
    # sed -Ei 和 sed -iE 是不同的
    if is_ltsc; then
        sed -Ei '/ltsc|ltsb/!d' $tmp/win.list
    else
        sed -Ei '/ltsc|ltsb/d' $tmp/win.list
    fi
}

get_shortest_line() {
    # awk '{print length($0), $0}' | sort -n | head -1 | awk '{print $2}'
    awk '(NR == 1 || length($0) < length(shortest)) { shortest = $0 } END { print shortest }'
}

get_windows_iso_link() {
    regexs=()

    # msdn
    if [ -n "$label_msdn" ]; then
        if [ "$label_msdn" = _ ]; then
            label_msdn=
        fi
        for lang in $langs; do
            regex=
            for i in ${lang} windows ${server} ${version} ${label_msdn}; do
                if [ -n "$i" ]; then
                    regex+="${i}_"
                fi
            done
            regex+=".*${arch_win}.*.iso"
            regexs+=("$regex")
        done
    fi

    # vlsc
    if [ -n "$label_vlsc" ]; then
        regex="sw_dvd9_win_${label_vlsc}_${version}.*${arch_win}_${full_lang}.*.iso"
        regexs+=("$regex")
    fi

    # 查找
    for regex in "${regexs[@]}"; do
        regex=${regex// /_}

        echo "looking for: $regex" >&2
        if iso=$(grep -Ei "/$regex" "$tmp/win.list" | get_shortest_line | grep .); then
            return
        fi
    done

    error_and_exit "Could not find windows iso."
}

setos() {
    local step=$1
    local distro=$2
    local releasever=$3
    info set $step $distro $releasever

    setos_netboot.xyz() {
        if is_efi; then
            if [ "$basearch" = aarch64 ]; then
                eval ${step}_efi=https://boot.netboot.xyz/ipxe/netboot.xyz-arm64.efi
            else
                eval ${step}_efi=https://boot.netboot.xyz/ipxe/netboot.xyz.efi
            fi
        else
            eval ${step}_vmlinuz=https://boot.netboot.xyz/ipxe/netboot.xyz.lkrn
        fi
    }

    setos_alpine() {
        is_virt && flavour=virt || flavour=lts

        # alpine aarch64 3.16/3.17 virt 没有直连链接
        if [ "$basearch" = aarch64 ] &&
            { [ "$releasever" = 3.16 ] || [ "$releasever" = 3.17 ]; }; then
            flavour=lts
        fi

        # 不要用https 因为甲骨文云arm initramfs阶段不会从硬件同步时钟，导致访问https出错
        if is_in_china; then
            mirror=http://mirror.nju.edu.cn/alpine/v$releasever
        else
            mirror=http://dl-cdn.alpinelinux.org/alpine/v$releasever
        fi
        eval ${step}_vmlinuz=$mirror/releases/$basearch/netboot/vmlinuz-$flavour
        eval ${step}_initrd=$mirror/releases/$basearch/netboot/initramfs-$flavour
        eval ${step}_modloop=$mirror/releases/$basearch/netboot/modloop-$flavour
        eval ${step}_repo=$mirror/main
    }

    setos_debian() {
        is_debian_eol() {
            [ "$releasever" -le 10 ]
        }

        case "$releasever" in
        9) codename=stretch ;;
        10) codename=buster ;;
        11) codename=bullseye ;;
        12) codename=bookworm ;;
        esac

        if is_in_china; then
            # 部分源没有 firmware
            # https://mirror.nju.edu.cn/debian-cdimage/firmware/
            cdimage_mirror=https://mirror.sjtu.edu.cn/debian-cdimage
        else
            cdimage_mirror=https://cdimage.debian.org/images # 在瑞典，不是 cdn
            # cloud.debian.org 同样在瑞典，不是 cdn
        fi

        if is_use_cloud_image; then
            # cloud image
            is_virt && ci_type=genericcloud || ci_type=generic
            eval ${step}_img=$cdimage_mirror/cloud/$codename/latest/debian-$releasever-$ci_type-$basearch_alt.qcow2
        else
            # 传统安装
            if is_debian_eol; then
                # https://github.com/tuna/issues/issues/1999
                # nju 也没同步
                if false && is_in_china; then
                    hostname=mirrors.tuna.tsinghua.edu.cn
                    hostname=mirror.nju.edu.cn
                    directory=debian-elts
                    initrd_mirror=mirrors.nju.edu.cn/debian-archive
                else
                    # 按道理不应该用官方源，但找不到其他源
                    hostname=deb.freexian.com
                    directory=extended-lts
                    initrd_mirror=archive.debian.org
                fi
                if is_in_china; then
                    warn "
Due to the lack of Debian Freexian ELTS instaler mirrors in China, the installation time may be longer.
Continue?

由于没有 Debian Freexian ELTS 国内安装源，安装时间可能会比较长。
继续安装?
"
                    read -r -p '[y/N]: '
                    if ! [[ "$REPLY" = [Yy] ]]; then
                        exit
                    fi
                fi
            else
                if is_in_china; then
                    # ftp.cn.debian.org 不在国内还严重丢包
                    # https://www.itdog.cn/ping/ftp.cn.debian.org
                    hostname=mirror.sjtu.edu.cn
                else
                    hostname=deb.debian.org # fastly
                fi
                directory=debian
                initrd_mirror=$hostname
            fi

            initrd_dir=debian/dists/$codename/main/installer-$basearch_alt/current/images/netboot/debian-installer/$basearch_alt

            is_virt && flavour=-cloud || flavour=
            # 甲骨文 arm64 cloud 内核 vnc 没有显示
            [ "$basearch_alt" = arm64 ] && flavour=

            eval ${step}_vmlinuz=https://$initrd_mirror/$initrd_dir/linux
            eval ${step}_initrd=https://$initrd_mirror/$initrd_dir/initrd.gz
            eval ${step}_ks=$confhome/debian.cfg
            eval ${step}_firmware=$cdimage_mirror/firmware/$codename/current/firmware.cpio.gz
            eval ${step}_hostname=$hostname
            eval ${step}_directory=$directory
            eval ${step}_codename=$codename
            eval ${step}_kernel=linux-image$flavour-$basearch_alt
        fi
    }

    setos_kali() {
        if is_use_cloud_image; then
            :
        else
            # 传统安装
            if is_in_china; then
                hostname=mirror.nju.edu.cn
            else
                # http.kali.org 没有 ipv6 地址
                # http.kali.org (geoip 重定向) 到 kali.download (cf)
                hostname=kali.download
            fi
            codename=kali-rolling
            mirror=http://$hostname/kali/dists/$codename/main/installer-$basearch_alt/current/images/netboot/debian-installer/$basearch_alt

            is_virt && flavour=-cloud || flavour=

            eval ${step}_vmlinuz=$mirror/linux
            eval ${step}_initrd=$mirror/initrd.gz
            eval ${step}_ks=$confhome/debian.cfg
            eval ${step}_hostname=$hostname
            eval ${step}_codename=$codename
            eval ${step}_directory=kali
            eval ${step}_kernel=linux-image$flavour-$basearch_alt
            # 缺少 firmware 下载
        fi
    }

    setos_ubuntu() {
        case "$releasever" in
        16.04) codename=xenial ;;
        18.04) codename=bionic ;;
        20.04) codename=focal ;;
        22.04) codename=jammy ;;
        24.04) codename=noble ;;
        esac

        if is_use_cloud_image; then
            # cloud image
            if is_in_china; then
                # 有的源没有 releases 镜像
                # https://mirrors.tuna.tsinghua.edu.cn/ubuntu-cloud-images/releases/
                #   https://unicom.mirrors.ustc.edu.cn/ubuntu-cloud-images/releases/
                #            https://mirror.nju.edu.cn/ubuntu-cloud-images/releases/

                # mirrors.cloud.tencent.com
                ci_mirror=https://mirror.nju.edu.cn/ubuntu-cloud-images
            else
                ci_mirror=https://cloud-images.ubuntu.com
            fi

            # 22.04 和以下没有 minimal aarch64 镜像
            is_have_minimal_image() {
                [ "$basearch_alt" = amd64 ] || [ "$releasever" = 24.04 ]
            }

            is_should_use_minimal_cloud_image() {
                if [ "$minimal" = 1 ] && ! is_have_minimal_image; then
                    echo "Fallback to normal cloud image."
                    return 1
                fi
                [ "$minimal" = 1 ]
            }

            get_suffix() {
                if [ "$releasever" = 16.04 ]; then
                    if is_efi; then
                        echo -uefi1
                    else
                        echo -disk1
                    fi
                fi
            }

            if is_should_use_minimal_cloud_image; then
                eval ${step}_img="$ci_mirror/minimal/releases/$codename/release/ubuntu-$releasever-minimal-cloudimg-$basearch_alt$(get_suffix).img"
            else
                eval ${step}_img="$ci_mirror/releases/$releasever/release/ubuntu-$releasever-server-cloudimg-$basearch_alt$(get_suffix).img"
            fi
        else
            # 传统安装
            if is_in_china; then
                case "$basearch" in
                "x86_64") mirror=https://mirror.nju.edu.cn/ubuntu-releases/$releasever ;;
                "aarch64") mirror=https://mirror.nju.edu.cn/ubuntu-cdimage/releases/$releasever/release ;;
                esac
            else
                case "$basearch" in
                "x86_64") mirror=https://releases.ubuntu.com/$releasever ;;
                "aarch64") mirror=https://cdimage.ubuntu.com/releases/$releasever/release ;;
                esac
            fi

            # iso
            filename=$(curl -L $mirror | grep -oP "ubuntu-$releasever.*?-live-server-$basearch_alt.iso" | head -1)
            iso=$mirror/$filename
            # 在 ubuntu 20.04 上，file 命令检测 ubuntu 22.04 iso 结果是 DOS/MBR boot sector
            test_url $iso 'iso|raw'
            eval ${step}_iso=$iso

            # ks
            eval ${step}_ks=$confhome/ubuntu.yaml
            eval ${step}_minimal=$minimal
        fi
    }

    setos_arch() {
        if [ "$basearch" = "x86_64" ]; then
            if is_in_china; then
                mirror=https://mirror.nju.edu.cn/archlinux
            else
                mirror=https://geo.mirror.pkgbuild.com # geoip
            fi
        else
            if is_in_china; then
                mirror=https://mirror.nju.edu.cn/archlinuxarm
            else
                # https 证书有问题
                mirror=http://mirror.archlinuxarm.org # geoip
            fi
        fi

        if is_use_cloud_image; then
            # cloud image
            eval ${step}_img=$mirror/images/latest/Arch-Linux-x86_64-cloudimg.qcow2
        else
            # 传统安装
            case "$basearch" in
            x86_64) dir="core/os/$basearch" ;;
            aarch64) dir="$basearch/core" ;;
            esac
            test_url $mirror/$dir/core.db gzip
            eval ${step}_mirror=$mirror
        fi
    }

    setos_nixos() {
        if is_in_china; then
            mirror=https://mirror.nju.edu.cn/nix-channels
        else
            mirror=https://nixos.org/channels
        fi

        if is_use_cloud_image; then
            :
        else
            # 传统安装
            # 该服务器文件缓存 miss 时会响应 206 + Location 头
            # 但 curl 这种情况不会重定向，所以添加 ascii 类型让它不要报错
            test_url $mirror/nixos-$releasever/store-paths.xz 'xz|ascii'
            eval ${step}_mirror=$mirror
        fi
    }

    setos_gentoo() {
        if is_in_china; then
            mirror=https://mirror.nju.edu.cn/gentoo
        else
            mirror=https://distfiles.gentoo.org # cdn77
        fi

        if is_use_cloud_image; then
            if [ "$basearch_alt" = arm64 ]; then
                error_and_exit 'Not support arm64 for gentoo cloud image.'
            fi

            # openrc 镜像没有附带兼容 cloud-init 的网络管理器
            eval ${step}_img=$mirror/experimental/$basearch_alt/openstack/gentoo-openstack-$basearch_alt-systemd-latest.qcow2
        else
            prefix=stage3-$basearch_alt-systemd
            dir=releases/$basearch_alt/autobuilds/current-$prefix
            file=$(curl -L $mirror/$dir/latest-$prefix.txt | grep '.tar.xz' | awk '{print $1}')
            stage3=$mirror/$dir/$file
            test_url $stage3 'xz'
            eval ${step}_img=$stage3
        fi
    }

    setos_opensuse() {
        # aria2 有 mata4 问题
        # https://download.opensuse.org/

        # 很多国内源缺少 aarch64 tumbleweed appliances
        #                 https://download.opensuse.org/ports/aarch64/tumbleweed/appliances/
        #           https://mirrors.nju.edu.cn/opensuse/ports/aarch64/tumbleweed/appliances/
        #          https://mirrors.ustc.edu.cn/opensuse/ports/aarch64/tumbleweed/appliances/
        # https://mirrors.tuna.tsinghua.edu.cn/opensuse/ports/aarch64/tumbleweed/appliances/

        if is_in_china; then
            mirror=https://mirror.sjtu.edu.cn/opensuse
        else
            mirror=https://provo-mirror.opensuse.org
        fi

        if [ "$releasever" = tumbleweed ]; then
            # tumbleweed
            if [ "$basearch" = aarch64 ]; then
                dir=ports/aarch64/tumbleweed/appliances
            else
                dir=tumbleweed/appliances
            fi
            file=openSUSE-Tumbleweed-Minimal-VM.$basearch-Cloud.qcow2
        else
            # 常规版本
            dir=distribution/leap/$releasever/appliances
            file=openSUSE-Leap-$releasever-Minimal-VM.$basearch-Cloud.qcow2
        fi

        # 有专门的kvm镜像，openSUSE-Leap-15.5-Minimal-VM.x86_64-kvm-and-xen.qcow2，但里面没有cloud-init
        eval ${step}_img=$mirror/$dir/$file
    }

    setos_windows() {
        if [ -z "$iso" ]; then
            # 查找时将 windows longhorn serverdatacenter 改成 windows server 2008 serverdatacenter
            image_name=${image_name/windows longhorn server/windows server 2008 server}
            echo "iso url is not set. Attempting to find it automatically."
            find_windows_iso
        fi

        # 将上面的 windows server 2008 serverdatacenter 改回 windows longhorn serverdatacenter
        # 也能纠正用户输入了 windows server 2008 serverdatacenter
        # 注意 windows server 2008 r2 serverdatacenter 不用改
        image_name=${image_name/windows server 2008 server/windows longhorn server}

        test_url $iso 'iso|raw'
        eval "${step}_iso='$iso'"
        eval "${step}_image_name='$image_name'"
    }

    # shellcheck disable=SC2154
    setos_dd() {
        # raw 包含 vhd
        test_url $img 'raw|raw.gzip|raw.xz' img_type

        if is_efi; then
            install_pkg hexdump

            extract() {
                case "$img_type_warp" in
                '') cat "$1" ;;
                xz | gzip)
                    install_pkg $img_type_warp
                    # xz/gzip -d 文件必须有正确的扩展名，否则报扩展名错误
                    # 因此用 stdin
                    "$img_type_warp" -dc <"$1"
                    ;;
                *) error_and_exit "warp type $img_type_warp not support." ;;
                esac
            }

            # openwrt 镜像 efi part type 不是 esp
            # 因此改成检测 fat?
            # https://downloads.openwrt.org/releases/23.05.3/targets/x86/64/openwrt-23.05.3-x86-64-generic-ext4-combined-efi.img.gz

            # od 在 coreutils 里面，好像要配合 tr 才能删除空格
            # hexdump 在 util-linux / bsdmainutils 里面
            # xxd 要单独安装，el 在 vim-common 里面
            # xxd -l $((34 * 4096)) -ps -c 128

            # 仅打印前34个扇区 * 4096字节（按最大的算）
            # 每行128字节
            extract "$tmp/img-test" | hexdump -n $((34 * 4096)) -e '128/1 "%02x" "\n"' -v >$tmp/img-test-hex
            if grep -q '^28732ac11ff8d211ba4b00a0c93ec93b' $tmp/img-test-hex; then
                echo 'DD: Image is EFI.'
            else
                echo 'DD: Image is not EFI.'
                warn '
The current machine uses EFI boot, but the DD image is not an EFI image.
Continue with DD?
当前机器使用 EFI 引导，但 DD 镜像可能不是 EFI 镜像。
继续 DD?'
                read -r -p '[y/N]: '
                if [[ "$REPLY" = [Yy] ]]; then
                    eval ${step}_confirmed_no_efi=1
                else
                    exit
                fi
            fi
        fi
        eval "${step}_img='$img'"
        eval "${step}_img_type='$img_type'"
        eval "${step}_img_type_warp='$img_type_warp'"
    }

    setos_centos_alma_rocky_fedora() {
        if is_use_cloud_image; then
            # ci
            if is_in_china; then
                case $distro in
                "centos") ci_mirror="https://mirror.nju.edu.cn/centos-cloud/centos" ;;
                "alma") ci_mirror="https://mirror.nju.edu.cn/almalinux/$releasever/cloud/$basearch/images" ;;
                "rocky") ci_mirror="https://mirror.nju.edu.cn/rocky/$releasever/images/$basearch" ;;
                "fedora") ci_mirror="https://mirror.nju.edu.cn/fedora/releases/$releasever/Cloud/$basearch/images" ;;
                esac
            else
                case $distro in
                "centos") ci_mirror="https://cloud.centos.org/centos" ;;
                "alma") ci_mirror="https://repo.almalinux.org/almalinux/$releasever/cloud/$basearch/images" ;;
                "rocky") ci_mirror="https://download.rockylinux.org/pub/rocky/$releasever/images/$basearch" ;;
                "fedora") ci_mirror="https://dl.fedoraproject.org/pub/fedora/linux/releases/$releasever/Cloud/$basearch/images" ;;
                esac
            fi
            case $distro in
            "centos")
                case $releasever in
                "7")
                    # aarch64 需要特殊处理
                    [ "$basearch" = aarch64 ] && ver=-2211 || ver=
                    ci_image=$ci_mirror/$releasever/images/CentOS-$releasever-$basearch-GenericCloud$ver.qcow2
                    ;;
                "9") ci_image=$ci_mirror/$releasever-stream/$basearch/images/CentOS-Stream-GenericCloud-$releasever-latest.$basearch.qcow2 ;;
                esac
                ;;
            "alma") ci_image=$ci_mirror/AlmaLinux-$releasever-GenericCloud-latest.$basearch.qcow2 ;;
            "rocky") ci_image=$ci_mirror/Rocky-$releasever-GenericCloud-Base.latest.$basearch.qcow2 ;;
            "fedora")
                # Fedora-Cloud-Base-39-1.5.x86_64.qcow2
                # Fedora-Cloud-Base-Generic.x86_64-40-1.14.qcow2
                page=$(curl -L $ci_mirror)
                # 40
                filename=$(grep -oP "Fedora-Cloud-Base-Generic.*?.qcow2" <<<"$page" | head -1)
                # 38/39
                if [ -z "$filename" ]; then
                    filename=$(grep -oP "Fedora-Cloud-Base-$releasever.*?.qcow2" <<<"$page" | head -1)
                fi
                ci_image=$ci_mirror/$filename
                ;;
            esac

            eval ${step}_img=${ci_image}
        else
            # 传统安装
            case $distro in
            "centos") mirrorlist="https://mirrors.centos.org/mirrorlist?repo=centos-baseos-$releasever-stream&arch=$basearch" ;;
            "alma") mirrorlist="https://mirrors.almalinux.org/mirrorlist/$releasever/baseos" ;;
            "rocky") mirrorlist="https://mirrors.rockylinux.org/mirrorlist?arch=$basearch&repo=BaseOS-$releasever" ;;
            "fedora") mirrorlist="https://mirrors.fedoraproject.org/mirrorlist?arch=$basearch&repo=fedora-$releasever" ;;
            esac

            # rocky/centos9 需要删除第一行注释， alma 需要替换$basearch
            for cur_mirror in $(curl -L $mirrorlist | sed "/^#/d" | sed "s,\$basearch,$basearch,"); do
                host=$(get_host_by_url $cur_mirror)
                if is_host_has_ipv4_and_ipv6 $host &&
                    test_url_grace ${cur_mirror}images/pxeboot/vmlinuz; then
                    mirror=$cur_mirror
                    break
                fi
            done

            if [ -z "$mirror" ]; then
                error_and_exit "All mirror failed."
            fi

            eval "${step}_mirrorlist='${mirrorlist}'"

            eval ${step}_ks=$confhome/redhat.cfg
            eval ${step}_vmlinuz=${mirror}images/pxeboot/vmlinuz
            eval ${step}_initrd=${mirror}images/pxeboot/initrd.img
            eval ${step}_squashfs=${mirror}images/install.img
            test_url ${mirror}images/install.img 'squashfs'
        fi
    }

    setos_oracle() {
        if is_use_cloud_image; then
            # ci
            install_pkg jq
            mirror=https://yum.oracle.com

            [ "$basearch" = aarch64 ] &&
                template_prefix=ol${releasever}_${basearch}-cloud ||
                template_prefix=ol${releasever}
            curl -Lo $tmp/oracle.json $mirror/templates/OracleLinux/$template_prefix-template.json
            dir=$(jq -r .base_url $tmp/oracle.json)
            file=$(jq -r .kvm.image $tmp/oracle.json)
            ci_image=$mirror$dir/$file

            eval ${step}_img=${ci_image}
        else
            :
        fi
    }

    setos_redhat() {
        if is_use_cloud_image; then
            # ci
            eval "${step}_img='$img'"
        else
            :
        fi
    }

    setos_opencloudos() {
        # https://mirrors.opencloudos.tech 不支持 ipv6
        mirror=https://mirrors.cloud.tencent.com/opencloudos
        if is_use_cloud_image; then
            # ci
            dir=$releasever/images/$basearch
            file=$(curl -L $mirror/$dir/ | grep -oP 'OpenCloudOS.*?\.qcow2' | head -1)
            eval ${step}_img=$mirror/$dir/$file
        else
            :
        fi
    }

    # anolis 23 不是 lts，而且 cloud-init 好像有问题
    setos_anolis() {
        mirror=https://mirrors.openanolis.cn/anolis
        if is_use_cloud_image; then
            # ci
            dir=$releasever/isos/GA/$basearch
            file=$(curl -L $mirror/$dir/ | grep -oP 'AnolisOS.*?\.qcow2' | head -1)
            eval ${step}_img=$mirror/$dir/$file
        else
            :
        fi
    }

    setos_openeuler() {
        if is_in_china; then
            mirror=https://repo.openeuler.openatom.cn
        else
            mirror=https://repo.openeuler.org
        fi
        if is_use_cloud_image; then
            # ci
            name=$(curl -L "$mirror/" | grep -oE "openEuler-$releasever-LTS(-SP[0-9])?" | sort -u | tail -1)
            eval ${step}_img=$mirror/$name/virtual_machine_img/$basearch/$name-$basearch.qcow2.xz
        else
            :
        fi
    }

    eval ${step}_distro=$distro
    eval ${step}_releasever=$releasever

    case "$distro" in
    centos | alma | rocky | fedora) setos_centos_alma_rocky_fedora ;;
    *) setos_$distro ;;
    esac

    # debian/kali <=256M 必须使用云内核，否则不够内存
    if is_distro_like_debian && ! is_in_windows && [ "$ram_size" -le 256 ]; then
        exit_if_cant_use_cloud_kernel
    fi

    # 集中测试云镜像格式
    if is_use_cloud_image && [ "$step" = finalos ]; then
        # shellcheck disable=SC2154
        test_url $finalos_img 'qemu|qemu.gzip|qemu.xz' finalos_img_type
    fi
}

is_distro_like_redhat() {
    if [ -n "$1" ]; then
        _distro=$1
    else
        _distro=$distro
    fi
    [ "$_distro" = redhat ] || [ "$_distro" = centos ] || [ "$_distro" = alma ] || [ "$_distro" = rocky ] || [ "$_distro" = fedora ] || [ "$_distro" = oracle ]
}

is_distro_like_debian() {
    if [ -n "$1" ]; then
        _distro=$1
    else
        _distro=$distro
    fi
    [ "$_distro" = debian ] || [ "$_distro" = kali ]
}

# 检查是否为正确的系统名
verify_os_name() {
    if [ -z "$*" ]; then
        usage_and_exit
    fi

    # 不要删除 centos 7
    for os in \
        'centos      7|9' \
        'anolis      7|8' \
        'alma        8|9' \
        'rocky       8|9' \
        'redhat      8|9' \
        'opencloudos 8|9' \
        'oracle      7|8|9' \
        'fedora      39|40' \
        'nixos       24.05' \
        'debian      9|10|11|12' \
        'openeuler   20.03|22.03|24.03' \
        'alpine      3.17|3.18|3.19|3.20' \
        'opensuse    15.5|15.6|tumbleweed' \
        'ubuntu      16.04|18.04|20.04|22.04|24.04' \
        'kali' \
        'arch' \
        'gentoo' \
        'windows' \
        'dd' \
        'netboot.xyz'; do
        read -r ds vers <<<"$os"
        vers_=${vers//\./\\\.}
        finalos=$(echo "$@" | to_lower | sed -n -E "s,^($ds)[ :-]?(|$vers_)$,\1 \2,p")
        if [ -n "$finalos" ]; then
            read -r distro releasever <<<"$finalos"
            # 默认版本号
            if [ -z "$releasever" ] && [ -n "$vers" ]; then
                releasever=$(awk -F '|' '{print $NF}' <<<"|$vers")
            fi
            return
        fi
    done

    error "Please specify a proper os"
    usage_and_exit
}

verify_os_args() {
    case "$distro" in
    dd) [ -n "$img" ] || error_and_exit "dd need --img" ;;
    redhat) [ -n "$img" ] || error_and_exit "redhat need --img" ;;
    windows) [ -n "$image_name" ] || error_and_exit "Install Windows need --image-name." ;;
    esac
}

get_cmd_path() {
    # arch 云镜像不带 which
    # command -v 包括脚本里面的方法
    # ash 无效
    type -f -p $1
}

is_have_cmd() {
    get_cmd_path $1 >/dev/null 2>&1
}

install_pkg() {
    is_in_windows && return

    find_pkg_mgr() {
        [ -n "$pkg_mgr" ] && return

        # 查找方法1: 通过 ID_LIKE / ID
        # 因为可能装了多种包管理器
        if [ -f /etc/os-release ]; then
            # shellcheck source=/dev/null
            . /etc/os-release
            for id in $ID_LIKE $ID; do
                # https://github.com/chef/os_release
                case "$id" in
                fedora | centos | rhel) is_have_cmd dnf && pkg_mgr=dnf || pkg_mgr=yum ;;
                debian | ubuntu) pkg_mgr=apt-get ;;
                opensuse | suse) pkg_mgr=zypper ;;
                alpine) pkg_mgr=apk ;;
                arch) pkg_mgr=pacman ;;
                gentoo) pkg_mgr=emerge ;;
                openwrt) pkg_mgr=opkg ;;
                nixos) pkg_mgr=nix-env ;;
                esac
                [ -n "$pkg_mgr" ] && return
            done
        fi

        # 查找方法 2
        for mgr in dnf yum apt-get pacman zypper emerge apk opkg nix-env; do
            is_have_cmd $mgr && pkg_mgr=$mgr && return
        done

        return 1
    }

    cmd_to_pkg() {
        unset USE
        case $cmd in
        ar)
            case "$pkg_mgr" in
            *) pkg="binutils" ;;
            esac
            ;;
        xz)
            case "$pkg_mgr" in
            apt-get) pkg="xz-utils" ;;
            *) pkg="xz" ;;
            esac
            ;;
        lsblk | findmnt)
            case "$pkg_mgr" in
            apk) pkg="$cmd" ;;
            *) pkg="util-linux" ;;
            esac
            ;;
        lsmem)
            case "$pkg_mgr" in
            apk) pkg="util-linux-misc" ;;
            *) pkg="util-linux" ;;
            esac
            ;;
        fdisk)
            case "$pkg_mgr" in
            apt-get) pkg="fdisk" ;;
            apk) pkg="util-linux-misc" ;;
            *) pkg="util-linux" ;;
            esac
            ;;
        hexdump)
            case "$pkg_mgr" in
            apt-get) pkg="bsdmainutils" ;;
            *) pkg="util-linux" ;;
            esac
            ;;
        unsquashfs)
            case "$pkg_mgr" in
            zypper) pkg="squashfs" ;;
            emerge) pkg="squashfs-tools" && export USE="lzma" ;;
            *) pkg="squashfs-tools" ;;
            esac
            ;;
        nslookup | dig)
            case "$pkg_mgr" in
            apt-get) pkg="dnsutils" ;;
            pacman) pkg="bind" ;;
            apk | emerge) pkg="bind-tools" ;;
            yum | dnf | zypper) pkg="bind-utils" ;;
            esac
            ;;
        *) pkg=$cmd ;;
        esac
    }

    # 系统                                 package名称              repo名称
    # centos/alma/rocky/fedora/anolis      epel-release             epel
    # oracle linux                         oracle-epel-release      ol9_developer_EPEL
    # opencloudos                          epol-release             EPOL
    check_is_need_epel() {
        is_need_epel() {
            case "$pkg" in
            dpkg) true ;;
            jq) is_have_cmd yum && ! is_have_cmd dnf ;; # el7/ol7 的 jq 在 epel 仓库
            *) false ;;
            esac
        }

        get_epel_repo_name() {
            # el7 不支持 yum repolist --all，要使用 yum repolist all
            # el7 yum repolist 第一栏有 /x86_64 后缀，因此要去掉。而 el9 没有
            $pkg_mgr repolist all | awk '{print $1}' | awk -F/ '{print $1}' | grep -Ei '(epel|epol)$'
        }

        get_epel_pkg_name() {
            $pkg_mgr list | grep -E '(epel|epol)-release' | awk '{print $1}' | cut -d. -f1 | head -1
        }

        if is_need_epel; then
            if ! epel=$(get_epel_repo_name); then
                $pkg_mgr install -y "$(get_epel_pkg_name)"
                epel=$(get_epel_repo_name)
            fi
            enable_epel="--enablerepo=$epel"
        else
            enable_epel=
        fi
    }

    install_pkg_real() {
        text="$pkg"
        if [ "$pkg" != "$cmd" ]; then
            text+=" ($cmd)"
        fi
        echo "Installing package '$text'..."

        case $pkg_mgr in
        dnf)
            check_is_need_epel
            dnf install $enable_epel -y --setopt=install_weak_deps=False $pkg
            ;;
        yum)
            check_is_need_epel
            yum install $enable_epel -y $pkg
            ;;
        emerge) emerge --oneshot $pkg ;;
        pacman) pacman -Syu --noconfirm --needed $pkg ;;
        zypper) zypper install -y $pkg ;;
        apk)
            add_community_repo_for_alpine
            apk add $pkg
            ;;
        apt-get)
            [ -z "$apt_updated" ] && apt-get update && apt_updated=1
            DEBIAN_FRONTEND=noninteractive apt-get install -y $pkg
            ;;
        opkg)
            [ -z "$opkg_updated" ] && opkg update && opkg_updated=1
            opkg install $pkg
            ;;
        nix-env)
            # 不指定 channel 会很慢，而且很占内存
            [ -z "$nix_updated" ] && nix-channel --update && nix_updated=1
            nix-env -iA nixos.$pkg
            ;;
        esac
    }

    is_need_reinstall() {
        cmd=$1

        # gentoo 默认编译的 unsquashfs 不支持 xz
        if [ "$cmd" = unsquashfs ] && is_have_cmd emerge && ! $cmd |& grep -wq xz; then
            echo "unsquashfs not supported xz. rebuilding."
            return 0
        fi

        # busybox fdisk 无法显示 mbr 分区表的 id
        if [ "$cmd" = fdisk ] && is_have_cmd apk && $cmd |& grep -wq BusyBox; then
            return 0
        fi

        # busybox grep 无法 grep -oP
        if [ "$cmd" = grep ] && is_have_cmd apk && $cmd |& grep -wq BusyBox; then
            return 0
        fi

        return 1
    }

    for cmd in "$@"; do
        if ! is_have_cmd $cmd || is_need_reinstall $cmd; then
            if ! find_pkg_mgr; then
                error_and_exit "Can't find compatible package manager. Please manually install $cmd."
            fi
            cmd_to_pkg
            install_pkg_real
        fi
    done >&2
}

check_ram() {
    ram_standard=$(
        case "$distro" in
        netboot.xyz) echo 0 ;;
        alpine | debian | kali | dd) echo 256 ;;
        arch | gentoo | nixos | windows) echo 512 ;;
        redhat | centos | alma | rocky | fedora | oracle | ubuntu | anolis | opencloudos | openeuler) echo 1024 ;;
        opensuse) echo -1 ;; # 没有安装模式
        esac
    )

    # 不用检查内存的情况
    if [ "$ram_standard" -eq 0 ]; then
        return
    fi

    # 未测试
    ram_cloud_image=256

    has_cloud_image=$(
        case "$distro" in
        redhat | centos | alma | rocky | oracle | fedora | debian | ubuntu | opensuse | anolis | openeuler) echo true ;;
        netboot.xyz | alpine | dd | arch | gentoo | nixos | kali | windows) echo false ;;
        esac
    )

    if is_in_windows; then
        ram_size=$(wmic memorychip get capacity | tail +2 | awk '{sum+=$1} END {print sum/1024/1024}')
    else
        # lsmem最准确但 centos7 arm 和 alpine 不能用，debian 9 util-linux 没有 lsmem
        # arm 24g dmidecode 显示少了128m
        # arm 24g lshw 显示23BiB
        # ec2 t4g arm alpine 用 lsmem 和 dmidecode 都无效，要用 lshw，但结果和free -m一致，其他平台则没问题
        install_pkg lsmem
        ram_size=$(lsmem -b 2>/dev/null | grep 'Total online memory:' | awk '{ print $NF/1024/1024 }')

        if [ -z $ram_size ]; then
            install_pkg dmidecode
            ram_size=$(dmidecode -t 17 | grep "Size.*[GM]B" | awk '{if ($3=="GB") s+=$2*1024; else s+=$2} END {print s}')
        fi

        if [ -z $ram_size ]; then
            install_pkg lshw
            # 不能忽略 -i，alpine 显示的是 System memory
            ram_str=$(lshw -c memory -short | grep -i 'System Memory' | awk '{print $3}')
            ram_size=$(grep <<<$ram_str -o '[0-9]*')
            grep <<<$ram_str GiB && ram_size=$((ram_size * 1024))
        fi
    fi

    if [ -z $ram_size ] || [ $ram_size -le 0 ]; then
        error_and_exit "Could not detect RAM size."
    fi

    # ram 足够就用普通方法安装，否则如果内存大于512就用 cloud image
    # TODO: 测试 256 384 内存
    if ! is_use_cloud_image && [ $ram_size -lt $ram_standard ]; then
        if $has_cloud_image; then
            info "RAM < $ram_standard MB. Fallback to cloud image mode"
            cloud_image=1
        else
            error_and_exit "Could not install $distro: RAM < $ram_standard MB."
        fi
    fi

    if is_use_cloud_image && [ $ram_size -lt $ram_cloud_image ]; then
        error_and_exit "Could not install $distro using cloud image: RAM < $ram_cloud_image MB."
    fi
}

is_efi() {
    if is_in_windows; then
        # bcdedit | grep -qi '^path.*\.efi'
        mountvol | grep -q --text 'EFI'
    else
        [ -d /sys/firmware/efi ]
    fi
}

is_grub_dir_linked() {
    # cloudcone 重装前/重装后(方法1)
    [ "$(readlink -f /boot/grub/grub.cfg)" = /boot/grub2/grub.cfg ] ||
        [ "$(readlink -f /boot/grub2/grub.cfg)" = /boot/grub/grub.cfg ] ||
        # cloudcone 重装后(方法2)
        { [ -f /boot/grub2/grub.cfg ] && [ "$(cat /boot/grub2/grub.cfg)" = 'chainloader (hd0)+1' ]; }
}

is_secure_boot_enabled() {
    if is_efi; then
        if is_in_windows; then
            reg query 'HKLM\SYSTEM\CurrentControlSet\Control\SecureBoot\State' /v UEFISecureBootEnabled 2>/dev/null | grep 0x1
        else
            if dmesg | grep -i 'Secure boot enabled'; then
                return 0
            fi
            install_pkg mokutil
            mokutil --sb-state 2>&1 | grep -i 'SecureBoot enabled'
        fi
    else
        return 1
    fi
}

is_need_grub_extlinux() {
    ! { is_netboot_xyz && is_efi; }
}

# 只有 linux bios 是用本机的 grub/extlinux
is_use_local_grub_extlinux() {
    is_need_grub_extlinux && ! is_in_windows && ! is_efi
}

is_use_local_grub() {
    is_use_local_grub_extlinux && is_mbr_using_grub
}

is_use_local_extlinux() {
    is_use_local_grub_extlinux && ! is_mbr_using_grub
}

is_mbr_using_grub() {
    find_main_disk
    # 各发行版不一定自带 strings hexdump xxd od 命令
    head -c 440 /dev/$xda | grep --text -iq 'GRUB'
}

to_upper() {
    tr '[:lower:]' '[:upper:]'
}

to_lower() {
    tr '[:upper:]' '[:lower:]'
}

del_cr() {
    sed 's/\r//g'
}

del_empty_lines() {
    sed '/^[[:space:]]*$/d'
}

# 记录主硬盘
find_main_disk() {
    if [ -n "$main_disk" ]; then
        return
    fi

    if is_in_windows; then
        # TODO:
        # 已测试 vista
        # 测试 软raid
        # 测试 动态磁盘

        # diskpart 命令结果
        # 磁盘 ID: E5FDE61C
        # 磁盘 ID: {92CF6564-9B2E-4348-A3BD-D84E3507EBD7}
        main_disk=$(printf "%s\n%s" "select volume $c" "uniqueid disk" | diskpart |
            tail -1 | awk '{print $NF}' | sed 's,[{}],,g' | del_cr)
    else
        # centos7下测试     lsblk --inverse $mapper | grep -w disk     grub2-probe -t disk /
        # 跨硬盘btrfs       只显示第一个硬盘                            显示两个硬盘
        # 跨硬盘lvm         显示两个硬盘                                显示/dev/mapper/centos-root
        # 跨硬盘软raid      显示两个硬盘                                显示/dev/md127

        # 还有 findmnt

        # 改成先检测 /boot/efi /efi /boot 分区？

        install_pkg lsblk
        # 查找主硬盘时，优先查找 /boot 分区，再查找 / 分区
        # lvm 显示的是 /dev/mapper/xxx-yyy，再用第二条命令得到sda
        mapper=$(mount | awk '$3=="/boot" {print $1}' | grep . || mount | awk '$3=="/" {print $1}')
        xda=$(lsblk -rn --inverse $mapper | grep -w disk | awk '{print $1}' | sort -u)

        # 检测主硬盘是否横跨多个磁盘
        os_across_disks_count=$(wc -l <<<"$xda")
        if [ $os_across_disks_count -eq 1 ]; then
            info "Main disk: $xda"
        else
            error_and_exit "OS across $os_across_disks_count disk: $xda"
        fi

        # 可以用 dd 找出 guid?

        # centos7 blkid lsblk 不显示 PTUUID
        # centos7 sfdisk 不显示 Disk identifier
        # alpine blkid 不显示 gpt 分区表的 PTUUID
        # 因此用 fdisk

        # Disk identifier: 0x36778223                                  # gnu fdisk + mbr
        # Disk identifier: D6B17C1A-FA1E-40A1-BDCB-0278A3ED9CFC        # gnu fdisk + gpt
        # Disk identifier (GUID): d6b17c1a-fa1e-40a1-bdcb-0278a3ed9cfc # busybox fdisk + gpt
        # 不显示 Disk identifier                                        # busybox fdisk + mbr

        # 获取 xda 的 id
        install_pkg fdisk
        main_disk=$(fdisk -l /dev/$xda | grep 'Disk identifier' | awk '{print $NF}' | sed 's/0x//')
    fi

    # 检查 id 格式是否正确
    if ! grep -Eix '[0-9a-f]{8}' <<<"$main_disk" &&
        ! grep -Eix '[0-9a-f-]{36}' <<<"$main_disk"; then
        error_and_exit "Disk ID is invalid: $main_disk"
    fi
}

is_found_ipv4_netconf() {
    [ -n "$ipv4_mac" ] && [ -n "$ipv4_addr" ] && [ -n "$ipv4_gateway" ]
}

is_found_ipv6_netconf() {
    [ -n "$ipv6_mac" ] && [ -n "$ipv6_addr" ] && [ -n "$ipv6_gateway" ]
}

# TODO: 单网卡多IP
collect_netconf() {
    if is_in_windows; then
        convert_net_str_to_array() {
            config=$1
            key=$2
            var=$3
            IFS=',' read -r -a "${var?}" <<<"$(grep "$key=" <<<"$config" | cut -d= -f2 | sed 's/[{}\"]//g')"
        }

        # 部分机器精简了 powershell
        # 所以不要用 powershell 获取网络信息
        # ids=$(wmic nic where "PhysicalAdapter=true and MACAddress is not null and (PNPDeviceID like '%VEN_%&DEV_%' or PNPDeviceID like '%{F8615163-DF3E-46C5-913F-F2D2F965ED0E}%')" get InterfaceIndex | del_cr | sed '1d')

        # 否        手动        0    0.0.0.0/0                  19  192.168.1.1
        # 否        手动        0    0.0.0.0/0                  59  nekoray-tun

        # wmic nic:
        # 真实网卡
        # AdapterType=以太网 802.3
        # AdapterTypeId=0
        # MACAddress=68:EC:C5:11:11:11
        # PhysicalAdapter=TRUE
        # PNPDeviceID=PCI\VEN_8086&amp;DEV_095A&amp;SUBSYS_94108086&amp;REV_61\4&amp;295A4BD&amp;1&amp;00E0

        # VPN tun 网卡，部分移动云电脑也有
        # AdapterType=
        # AdapterTypeId=
        # MACAddress=
        # PhysicalAdapter=TRUE
        # PNPDeviceID=SWD\WINTUN\{6A460D48-FB76-6C3F-A47D-EF97D3DC6B0E}

        # VMware 网卡
        # AdapterType=以太网 802.3
        # AdapterTypeId=0
        # MACAddress=00:50:56:C0:00:08
        # PhysicalAdapter=TRUE
        # PNPDeviceID=ROOT\VMWARE\0001

        for v in 4 6; do
            if [ "$v" = 4 ]; then
                # 或者 route print
                routes=$(netsh int ipv4 show route | awk '$4 == "0.0.0.0/0"' | del_cr)
            else
                routes=$(netsh int ipv6 show route | awk '$4 == "::/0"' | del_cr)
            fi

            if [ -z "$routes" ]; then
                continue
            fi

            while read -r route; do
                if false; then
                    read -r _ _ _ _ id gateway <<<"$route"
                else
                    id=$(awk '{print $5}' <<<"$route")
                    gateway=$(awk '{print $6}' <<<"$route")
                fi

                config=$(wmic nicconfig where InterfaceIndex=$id get MACAddress,IPAddress,IPSubnet,DefaultIPGateway /format:list | del_cr)
                # 排除 IP/子网/网关/MAC 为空的
                if grep -q '=$' <<<"$config"; then
                    continue
                fi

                mac_addr=$(grep "MACAddress=" <<<"$config" | cut -d= -f2 | to_lower)
                convert_net_str_to_array "$config" IPAddress ips
                convert_net_str_to_array "$config" IPSubnet subnets
                convert_net_str_to_array "$config" DefaultIPGateway gateways

                # IPv4
                # shellcheck disable=SC2154
                if [ "$v" = 4 ]; then
                    for ((i = 0; i < ${#ips[@]}; i++)); do
                        ip=${ips[i]}
                        subnet=${subnets[i]}
                        if [[ "$ip" = *.* ]]; then
                            cidr=$(ipcalc -b "$ip/$subnet" | grep Netmask: | awk '{print $NF}')
                            ipv4_addr="$ip/$cidr"
                            ipv4_gateway="$gateway"
                            ipv4_mac="$mac_addr"
                            # 只取第一个 IP
                            break
                        fi
                    done
                fi

                # IPv6
                if [ "$v" = 6 ]; then
                    ipv6_type_list=$(netsh interface ipv6 show address $id normal)
                    for ((i = 0; i < ${#ips[@]}; i++)); do
                        ip=${ips[i]}
                        cidr=${subnets[i]}
                        if [[ "$ip" = *:* ]]; then
                            ipv6_type=$(grep "$ip" <<<"$ipv6_type_list" | awk '{print $1}')
                            # Public 是 slaac
                            # 还有类型 Temporary，不过有 Temporary 肯定还有 Public，因此不用
                            if [ "$ipv6_type" = Public ] ||
                                [ "$ipv6_type" = Dhcp ] ||
                                [ "$ipv6_type" = Manual ]; then
                                ipv6_addr="$ip/$cidr"
                                ipv6_gateway="$gateway"
                                ipv6_mac="$mac_addr"
                                # 只取第一个 IP
                                break
                            fi
                        fi
                    done
                fi

                # 网关
                # shellcheck disable=SC2154
                if false; then
                    for gateway in "${gateways[@]}"; do
                        if [ -n "$ipv4_addr" ] && [[ "$gateway" = *.* ]]; then
                            ipv4_gateway="$gateway"
                        elif [ -n "$ipv6_addr" ] && [[ "$gateway" = *:* ]]; then
                            ipv6_gateway="$gateway"
                        fi
                    done
                fi

                # 如果通过本条 route 的网卡找到了 IP 则退出 routes 循环
                if is_found_ipv${v}_netconf; then
                    break
                fi
            done < <(echo "$routes")
        done
    else
        # linux
        # 通过默认网关得到默认网卡

        # 多个默认路由下
        # ip -6 route show default dev ens3 完全不显示

        # ip -6 route show default
        # default proto static metric 1024 pref medium
        #         nexthop via 2a01:1111:262:4940::2 dev ens3 weight 1 onlink
        #         nexthop via fe80::5054:ff:fed4:5286 dev ens3 weight 1

        # ip -6 route show default
        # default via 2602:1111:0:80::1 dev eth0 metric 1024 onlink pref medium

        for v in 4 6; do
            if ethx=$(ip -$v route show default | awk '$4=="dev"' | head -1 | awk '{print $5}' | grep .); then
                if ip -$v route show default | awk '$5=="'$ethx'"' | head -1 | grep -q .; then
                    eval ipv${v}_ethx="$ethx" # can_use_cloud_kernel 要用
                    eval ipv${v}_mac="$(ip link show dev $ethx | grep link/ether | head -1 | awk '{print $2}')"
                    eval ipv${v}_gateway="$(ip -$v route show default | awk '$5=="'$ethx'"' | head -1 | awk '{print $3}')"
                    eval ipv${v}_addr="$(ip -$v -o addr show scope global dev $ethx | grep -v temporary | head -1 | awk '{print $4}')"
                fi
            fi
        done
    fi

    if ! is_found_ipv4_netconf && ! is_found_ipv6_netconf; then
        error_and_exit "Can not get IP info."
    fi

    info "Network Info"
    echo "IPv4 MAC: $ipv4_mac"
    echo "IPv4 Address: $ipv4_addr"
    echo "IPv4 Gateway: $ipv4_gateway"
    echo "---"
    echo "IPv6 MAC: $ipv6_mac"
    echo "IPv6 Address: $ipv6_addr"
    echo "IPv6 Gateway: $ipv6_gateway"
    echo
}

add_efi_entry_in_windows() {
    source=$1

    # 挂载
    if result=$(find /cygdrive/?/EFI/Microsoft/Boot/bootmgfw.efi 2>/dev/null); then
        # 已经挂载
        x=$(echo $result | cut -d/ -f3)
    else
        # 找到空盘符并挂载
        for x in {a..z}; do
            [ ! -e /cygdrive/$x ] && break
        done
        mountvol $x: /s
    fi

    # 文件夹命名为reinstall而不是grub，因为可能机器已经安装了grub，bcdedit名字同理
    dist_dir=/cygdrive/$x/EFI/reinstall
    basename=$(basename $source)
    mkdir -p $dist_dir
    cp -f "$source" "$dist_dir/$basename"

    # 如果 {fwbootmgr} displayorder 为空
    # 执行 bcdedit /copy '{bootmgr}' 会报错
    # 例如 azure windows 2016 模板
    # 要先设置默认的 {fwbootmgr} displayorder
    # https://github.com/hakuna-m/wubiuefi/issues/286
    bcdedit /set '{fwbootmgr}' displayorder '{bootmgr}' /addfirst

    # 添加启动项
    id=$(bcdedit /copy '{bootmgr}' /d "$(get_entry_name)" | grep -o '{.*}')
    bcdedit /set $id device partition=$x:
    bcdedit /set $id path \\EFI\\reinstall\\$basename
    bcdedit /set '{fwbootmgr}' bootsequence $id
}

get_maybe_efi_dirs_in_linux() {
    # arch云镜像efi分区挂载在/efi，且使用 autofs，挂载后会有两个 /efi 条目
    # openEuler 云镜像 boot 分区是 vfat 格式，但 vfat 可以当 efi 分区用
    # TODO: 最好通过 lsblk/blkid 检查是否为 efi 分区类型
    mount | awk '$5=="vfat" || $5=="autofs" {print $3}' | grep -E '/boot|/efi' | sort -u
}

get_disk_by_part() {
    dev_part=$1
    install_pkg lsblk >&2
    lsblk -rn --inverse "$dev_part" | grep -w disk | awk '{print $1}'
}

get_part_num_by_part() {
    dev_part=$1
    grep -oE '[0-9]*$' <<<"$dev_part"
}

grep_efi_entry() {
    # efibootmgr
    # BootCurrent: 0002
    # Timeout: 1 seconds
    # BootOrder: 0000,0002,0003,0001
    # Boot0000* sles-secureboot
    # Boot0001* CD/DVD Rom
    # Boot0002* Hard Disk
    # Boot0003* sles-secureboot
    # MirroredPercentageAbove4G: 0.00
    # MirrorMemoryBelow4GB: false

    # 根据文档，* 表示 active，也就是说有可能没有*(代表inactive)
    # https://manpages.debian.org/testing/efibootmgr/efibootmgr.8.en.html
    grep -E '^Boot[0-9a-fA-F]{4}'
}

grep_efi_index() {
    awk '{print $1}' | sed -e 's/Boot//' -e 's/\*//'
}

add_efi_entry_in_linux() {
    source=$1

    install_pkg efibootmgr

    for efi_part in $(get_maybe_efi_dirs_in_linux); do
        if find $efi_part -iname "*.efi" >/dev/null; then
            dist_dir=$efi_part/EFI/reinstall
            basename=$(basename $source)
            mkdir -p $dist_dir

            if [[ "$source" = http* ]]; then
                curl -Lo "$dist_dir/$basename" "$source"
            else
                cp -f "$source" "$dist_dir/$basename"
            fi

            if false; then
                grub_probe="$(command -v grub-probe grub2-probe)"
                dev_part="$("$grub_probe" -t device "$dist_dir")"
            else
                install_pkg findmnt
                # arch findmnt 会得到
                # systemd-1
                # /dev/sda2
                dev_part=$(findmnt -T "$dist_dir" -no SOURCE | grep '^/dev/')
            fi

            id=$(efibootmgr --create-only \
                --disk "/dev/$(get_disk_by_part $dev_part)" \
                --part "$(get_part_num_by_part $dev_part)" \
                --label "$(get_entry_name)" \
                --loader "\\EFI\\reinstall\\$basename" |
                grep_efi_entry | tail -1 | grep_efi_index)
            efibootmgr --bootnext $id
            return
        fi
    done

    error_and_exit "Can't find efi partition."
}

install_grub_linux_efi() {
    info 'download grub efi'

    if [ "$basearch" = aarch64 ]; then
        grub_efi=grubaa64.efi
    else
        grub_efi=grubx64.efi
    fi

    # fedora 39 的 efi 无法识别 opensuse tumbleweed 的 xfs
    efi_distro=opensuse

    # 不要用 download.opensuse.org 和 download.fedoraproject.org
    # 因为 ipv6 访问有时跳转到 ipv4 地址，造成 ipv6 only 机器无法下载
    # 日韩机器有时得到国内镜像源，但镜像源屏蔽了国外 IP 导致连不上
    # https://mirrors.bfsu.edu.cn/opensuse/ports/aarch64/tumbleweed/repo/oss/EFI/BOOT/grub.efi

    # fcix 经常 404
    # https://mirror.fcix.net/opensuse/tumbleweed/repo/oss/EFI/BOOT/bootx64.efi
    # https://mirror.fcix.net/opensuse/tumbleweed/appliances/openSUSE-Tumbleweed-Minimal-VM.x86_64-Cloud.qcow2
    if [ "$efi_distro" = fedora ]; then
        fedora_ver=40

        if is_in_china; then
            mirror=https://mirror.nju.edu.cn/fedora
        else
            mirror=https://dl.fedoraproject.org/pub/fedora/linux
        fi

        curl -Lo $tmp/$grub_efi $mirror/releases/$fedora_ver/Everything/$basearch/os/EFI/BOOT/$grub_efi
    else
        if is_in_china; then
            mirror=https://mirror.sjtu.edu.cn/opensuse
        else
            mirror=https://provo-mirror.opensuse.org
        fi

        [ "$basearch" = x86_64 ] && ports='' || ports=/ports/$basearch

        curl -Lo $tmp/$grub_efi $mirror$ports/tumbleweed/repo/oss/EFI/BOOT/grub.efi
    fi

    add_efi_entry_in_linux $tmp/$grub_efi
}

install_grub_win() {
    # 下载 grub
    info download grub
    grub_ver=2.06
    # ftpmirror.gnu.org 是 geoip 重定向，不是 cdn
    # 有可能重定义到一个拉黑了部分 IP 的服务器
    is_in_china && grub_url=https://mirror.nju.edu.cn/gnu/grub/grub-$grub_ver-for-windows.zip ||
        grub_url=https://mirrors.kernel.org/gnu/grub/grub-$grub_ver-for-windows.zip
    curl -Lo $tmp/grub.zip $grub_url
    # unzip -qo $tmp/grub.zip
    7z x $tmp/grub.zip -o$tmp -r -y -xr!i386-efi -xr!locale -xr!themes -bso0
    grub_dir=$tmp/grub-$grub_ver-for-windows
    grub=$grub_dir/grub

    # 设置 grub 包含的模块
    # 原系统是 windows，因此不需要 ext2 lvm xfs btrfs
    grub_modules+=" normal minicmd serial ls echo test cat reboot halt linux chain search all_video configfile"
    grub_modules+=" scsi part_msdos part_gpt fat ntfs ntfscomp lzopio xzio gzio zstd"
    if ! is_efi; then
        grub_modules+=" biosdisk linux16"
    fi

    # 设置 grub prefix 为c盘根目录
    # 运行 grub-probe 会改变cmd窗口字体
    prefix=$($grub-probe -t drive $c: | sed 's|.*PhysicalDrive|(hd|' | del_cr)/
    echo $prefix

    # 安装 grub
    if is_efi; then
        # efi
        info install grub for efi
        if [ "$basearch" = aarch64 ]; then
            # 3.20 是 grub 2.12，可能会有问题
            alpine_ver=3.19
            is_in_china && mirror=http://mirror.nju.edu.cn/alpine || mirror=https://dl-cdn.alpinelinux.org/alpine
            grub_efi_apk=$(curl -L $mirror/v$alpine_ver/main/aarch64/ | grep -oP 'grub-efi-.*?apk' | head -1)
            mkdir -p $tmp/grub-efi
            curl -L "$mirror/v$alpine_ver/main/aarch64/$grub_efi_apk" | tar xz --warning=no-unknown-keyword -C $tmp/grub-efi/
            cp -r $tmp/grub-efi/usr/lib/grub/arm64-efi/ $grub_dir
            $grub-mkimage -p $prefix -O arm64-efi -o "$(cygpath -w $grub_dir/grubaa64.efi)" $grub_modules
            add_efi_entry_in_windows $grub_dir/grubaa64.efi
        else
            $grub-mkimage -p $prefix -O x86_64-efi -o "$(cygpath -w $grub_dir/grubx64.efi)" $grub_modules
            add_efi_entry_in_windows $grub_dir/grubx64.efi
        fi
    else
        # bios
        info install grub for bios

        # bootmgr 加载 g2ldr 有大小限制
        # 超过大小会报错 0xc000007b
        # 解决方法1 g2ldr.mbr + g2ldr
        # 解决方法2 生成少于64K的 g2ldr + 动态模块
        if false; then
            # g2ldr.mbr
            # 部分国内机无法访问 ftp.cn.debian.org
            is_in_china && host=mirror.nju.edu.cn || host=deb.debian.org
            curl -LO http://$host/debian/tools/win32-loader/stable/win32-loader.exe
            7z x win32-loader.exe 'g2ldr.mbr' -o$tmp/win32-loader -r -y -bso0
            find $tmp/win32-loader -name 'g2ldr.mbr' -exec cp {} /cygdrive/$c/ \;

            # g2ldr
            # 配置文件 c:\grub.cfg
            $grub-mkimage -p "$prefix" -O i386-pc -o "$(cygpath -w $grub_dir/core.img)" $grub_modules
            cat $grub_dir/i386-pc/lnxboot.img $grub_dir/core.img >/cygdrive/$c/g2ldr
        else
            # grub-install 无法设置 prefix
            # 配置文件 c:\grub\grub.cfg
            $grub-install $c \
                --target=i386-pc \
                --boot-directory=$c: \
                --install-modules="$grub_modules" \
                --themes= \
                --fonts= \
                --no-bootsector

            cat $grub_dir/i386-pc/lnxboot.img /cygdrive/$c/grub/i386-pc/core.img >/cygdrive/$c/g2ldr
        fi

        # 添加引导
        # 脚本可能不是首次运行，所以先删除原来的
        id='{1c41f649-1637-52f1-aea8-f96bfebeecc8}'
        bcdedit /enum all | grep --text $id && bcdedit /delete $id
        bcdedit /create $id /d "$(get_entry_name)" /application bootsector
        bcdedit /set $id device partition=$c:
        bcdedit /set $id path \\g2ldr
        bcdedit /displayorder $id /addlast
        bcdedit /bootsequence $id /addfirst
    fi
}

find_grub_extlinux_cfg() {
    dir=$1
    filename=$2
    keyword=$3

    # 当 ln -s /boot/grub /boot/grub2 时
    # find /boot/ 会自动忽略 /boot/grub2 里面的文件
    cfgs=$(
        # 只要 $dir 存在
        # 无论是否找到结果，返回值都是 0
        find $dir \
            -type f -name $filename \
            -exec grep -E -l "$keyword" {} \;
    )

    count="$(wc -l <<<"$cfgs")"
    if [ "$count" -eq 1 ]; then
        echo "$cfgs"
    else
        error_and_exit "Find $count $filename."
    fi
}

# 转换 finalos_a=1 为 finalos.a=1 ，排除 finalos_mirrorlist
build_finalos_cmdline() {
    if vars=$(compgen -v finalos_); then
        for key in $vars; do
            value=${!key}
            key=${key#finalos_}
            if [ -n "$value" ] && [ $key != "mirrorlist" ]; then
                finalos_cmdline+=" finalos_$key='$value'"
            fi
        done
    fi
}

build_extra_cmdline() {
    # 使用 extra_xxx=yyy 而不是 extra.xxx=yyy
    # 因为 debian installer /lib/debian-installer-startup.d/S02module-params
    # 会将 extra.xxx=yyy 写入新系统的 /etc/modprobe.d/local.conf
    # https://answers.launchpad.net/ubuntu/+question/249456
    # https://salsa.debian.org/installer-team/rootskel/-/blob/master/src/lib/debian-installer-startup.d/S02module-params?ref_type=heads
    for key in confhome hold force cloud_image main_disk; do
        value=${!key}
        if [ -n "$value" ]; then
            extra_cmdline+=" extra_$key='$value'"
        fi
    done

    # 指定最终安装系统的 mirrorlist，链接有&，在grub中是特殊字符，所以要加引号
    if [ -n "$finalos_mirrorlist" ]; then
        extra_cmdline+=" extra_mirrorlist='$finalos_mirrorlist'"
    elif [ -n "$nextos_mirrorlist" ]; then
        extra_cmdline+=" extra_mirrorlist='$nextos_mirrorlist'"
    fi

    # cloudcone 特殊处理
    if is_grub_dir_linked; then
        finalos_cmdline+=" extra_link_grub_dir=1"
    fi
}

echo_tmp_ttys() {
    if false; then
        curl -L $confhome/ttys.sh | sh -s "console="
    else
        case "$basearch" in
        x86_64) echo "console=ttyS0,115200n8 console=tty0" ;;
        aarch64) echo "console=ttyS0,115200n8 console=ttyAMA0,115200n8 console=tty0" ;;
        esac
    fi
}

get_entry_name() {
    printf 'reinstall ('
    printf '%s' "$distro"
    [ -n "$releasever" ] && printf ' %s' "$releasever"
    [ "$distro" = alpine ] && [ "$hold" = 1 ] && printf ' Live OS'
    printf ')'
}

# shellcheck disable=SC2154
build_nextos_cmdline() {
    if [ $nextos_distro = alpine ]; then
        nextos_cmdline="alpine_repo=$nextos_repo modloop=$nextos_modloop"
    elif is_distro_like_debian $nextos_distro; then
        nextos_cmdline="lowmem/low=1 auto=true priority=critical"
        nextos_cmdline+=" url=$nextos_ks"
        nextos_cmdline+=" mirror/http/hostname=$nextos_hostname"
        nextos_cmdline+=" mirror/http/directory=/$nextos_directory"
        nextos_cmdline+=" base-installer/kernel/image=$nextos_kernel"
        # eol 的 debian 不能用 security 源，否则安装过程会提示无法访问
        if [ "$nextos_distro" = debian ] && is_debian_eol; then
            nextos_cmdline+=" apt-setup/services-select="
        fi
        # kali 安装好后网卡是 eth0 这种格式，但安装时不是
        if [ "$nextos_distro" = kali ]; then
            nextos_cmdline+=" net.ifnames=0"
            nextos_cmdline+=" simple-cdd/profiles=kali"
        fi
    elif is_distro_like_redhat $nextos_distro; then
        # redhat
        nextos_cmdline="root=live:$nextos_squashfs inst.ks=$nextos_ks"
    fi

    if is_distro_like_debian $nextos_distro; then
        if [ "$basearch" = "x86_64" ]; then
            # debian installer 好像第一个 tty 是主 tty
            # 设置ttyS0,tty0,安装界面还是显示在ttyS0
            :
        else
            # debian arm 在没有ttyAMA0的机器上（aws t4g），最少要设置一个tty才能启动
            # 只设置tty0也行，但安装过程ttyS0没有显示
            nextos_cmdline+=" $(echo_tmp_ttys)"
        fi
    else
        nextos_cmdline+=" $(echo_tmp_ttys)"
    fi
    # nextos_cmdline+=" mem=256M"
    # nextos_cmdline+=" lowmem=+1"
}

build_cmdline() {
    # nextos
    build_nextos_cmdline

    # finalos
    # trans 需要 finalos_distro 识别是安装 alpine 还是其他系统
    if [ "$distro" = alpine ]; then
        finalos_distro=alpine
    fi
    if [ -n "$finalos_distro" ]; then
        build_finalos_cmdline
    fi

    # extra
    build_extra_cmdline

    cmdline="$nextos_cmdline $finalos_cmdline $extra_cmdline"
}

# 脚本可能多次运行，先清理之前的残留
mkdir_clear() {
    dir=$1

    if [ -z "$dir" ] || [ "$dir" = / ]; then
        return
    fi

    # alpine 没有 -R
    # { umount $dir || umount -R $dir || true; } 2>/dev/null
    rm -rf $dir
    mkdir -p $dir
}

mod_initrd_debian_kali() {
    # hack 1
    # 允许设置 ipv4 onlink 网关
    sed -Ei 's,&&( onlink=),||\1,' etc/udhcpc/default.script

    # hack 2
    # 修改 /var/lib/dpkg/info/netcfg.postinst 运行我们的脚本
    netcfg() {
        #!/bin/sh
        # shellcheck source=/dev/null
        . /usr/share/debconf/confmodule
        db_progress START 0 5 debian-installer/netcfg/title

        : get_ip_conf_cmd

        # 运行 trans.sh，保存配置
        db_progress INFO base-installer/progress/netcfg
        sh /trans.sh
        db_progress STEP 1
    }

    # 直接覆盖 net-retriever，方便调试
    # curl -Lo /usr/lib/debian-installer/retriever/net-retriever $confhome/net-retriever

    postinst=var/lib/dpkg/info/netcfg.postinst
    get_function_content netcfg >$postinst
    get_ip_conf_cmd | insert_into_file $postinst after ": get_ip_conf_cmd"
    # cat $postinst

    # shellcheck disable=SC2317
    change_priority() {
        while IFS= read -r line; do
            key_=$(echo "$line" | cut -d' ' -f1)
            value=$(echo "$line" | cut -d' ' -f2-)

            case "$key_" in
            Package:)
                package="$value"
                ;;
            Priority:)
                # shellcheck disable=SC2154
                if [ "$value" = standard ] && echo "$disabled_list" | grep -qx "$package"; then
                    line="Priority: optional"
                elif [[ "$package" = ata-modules* ]]; then
                    # 改成强制安装
                    # 因为是 pata-modules sata-modules scsi-modules 的依赖
                    # 但我们没安装它们，也就不会自动安装 ata-modules
                    line="Priority: standard"
                fi
                ;;
            esac
            echo "$line"
        done
    }

    # shellcheck disable=SC2012
    kver=$(ls -d lib/modules/* | awk -F/ '{print $NF}')

    net_retriever=usr/lib/debian-installer/retriever/net-retriever
    # shellcheck disable=SC2016
    sed -i 's,>> "$1",| change_priority >> "$1",' $net_retriever
    insert_into_file $net_retriever after '#!/bin/sh' <<EOF
disabled_list="
depthcharge-tools-installer
kickseed-common
nobootloader
partman-btrfs
partman-cros
partman-iscsi
partman-jfs
partman-md
rescue-check
wpasupplicant-udeb
lilo-installer
nic-modules-$kver-di
nic-pcmcia-modules-$kver-di
nic-usb-modules-$kver-di
nic-wireless-modules-$kver-di
nic-shared-modules-$kver-di
pcmcia-modules-$kver-di
pcmcia-storage-modules-$kver-di
cdrom-core-modules-$kver-di
firewire-core-modules-$kver-di
usb-storage-modules-$kver-di
isofs-modules-$kver-di
jfs-modules-$kver-di
loop-modules-$kver-di
pata-modules-$kver-di
sata-modules-$kver-di
scsi-modules-$kver-di
"

$(get_function change_priority)
EOF

    # https://github.com/linuxhw/LsPCI?tab=readme-ov-file#storageata-pci
    # https://debian.pkgs.org/12/debian-main-amd64/linux-image-6.1.0-18-cloud-amd64_6.1.76-1_amd64.deb.html
    # https://deb.debian.org/debian/pool/main/l/linux-signed-amd64/
    # https://deb.debian.org/debian/dists/bookworm/main/debian-installer/binary-all/Packages.xz
    # https://deb.debian.org/debian/dists/bookworm/main/debian-installer/binary-amd64/Packages.xz
    # 以下是 debian-installer 有的驱动，这些驱动云内核不一定都有，(+)表示云内核有
    # scsi-core-modules 默认安装（不用修改），是 ata-modules 的依赖
    #                   包含 sd_mod.ko(+) scsi_mod.ko(+) scsi_transport_fc.ko(+) scsi_transport_sas.ko(+) scsi_transport_spi.ko(+)
    # ata-modules       默认可选（改成必装），是下方模块的依赖。只有 ata_generic.ko(+) 和 libata.ko(+) 两个驱动

    # pata-modules      默认安装（改成可选），里面的驱动都是 pata_ 开头，但只有 pata_legacy.ko(+) 在云内核中
    # sata-modules      默认安装（改成可选），里面的驱动大部分是 sata_ 开头的，其他重要的还有 ahci.ko libahci.ko ata_piix.ko(+)
    #                   云内核没有 sata 模块，也没有内嵌，有一个 CONFIG_SATA_HOST=y，libata-$(CONFIG_SATA_HOST)	+= libata-sata.o
    # scsi-modules      默认安装（改成可选），包含 nvme.ko(+) 和各种虚拟化驱动(+)

    download_and_extract_udeb() {
        package=$1
        extract_dir=$2

        # 获取 udeb 列表
        udeb_list=$tmp/udeb_list
        if ! [ -f $udeb_list ]; then
            # shellcheck disable=SC2154
            curl -L http://$nextos_hostname/$nextos_directory/dists/$nextos_codename/main/debian-installer/binary-$basearch_alt/Packages.gz |
                zcat | grep 'Filename:' | awk '{print $2}' >$udeb_list
        fi

        # 下载 udeb
        curl -Lo $tmp/tmp.udeb http://$nextos_hostname/$nextos_directory/"$(grep /$package $udeb_list)"

        if false; then
            # 使用 dpkg
            # cygwin 没有 dpkg
            install_pkg dpkg
            dpkg -x $tmp/tmp.udeb $extract_dir
        else
            # 使用 ar tar xz
            # cygwin 需安装 binutils
            # centos7 ar 不支持 --output
            install_pkg ar tar xz
            (cd $tmp && ar x $tmp/tmp.udeb)
            tar xf $tmp/data.tar.xz -C $extract_dir
        fi
    }

    # 不用在 windows 判断是哪种硬盘控制器，因为 256M 运行 windows 只可能是 xp，而脚本本来就不支持 xp
    # 在 debian installer 中判断能否用云内核
    create_can_use_cloud_kernel_sh can_use_cloud_kernel.sh

    # 最近 kali initrd 删除了原版 wget
    # 但 initrd 的 busybox wget 又不支持 https
    # 因此改成在这里下载
    curl -LO "$confhome/get-xda.sh"
    curl -LO "$confhome/ttys.sh"

    # 可以节省一点内存？
    echo 'export DEBCONF_DROP_TRANSLATIONS=1' |
        insert_into_file lib/debian-installer/menu before 'exec debconf'

    # 还原 kali netinst.iso 的 simple-cdd 机制
    # 主要用于调用 kali.postinst 设置 zsh 为默认 shell
    # 但 mini.iso 又没有这种机制
    # https://gitlab.com/kalilinux/build-scripts/live-build-config/-/raw/master/kali-config/common/includes.installer/kali-finish-install?ref_type=heads
    # https://salsa.debian.org/debian/simple-cdd/-/blob/master/debian/14simple-cdd?ref_type=heads
    # https://http.kali.org/pool/main/s/simple-cdd/simple-cdd-profiles_0.6.9_all.udeb
    if [ "$distro" = kali ]; then
        # 但我们没有使用 iso，因此没有 kali.postinst，需要另外下载
        mkdir -p cdrom/simple-cdd
        curl -Lo cdrom/simple-cdd/kali.postinst https://gitlab.com/kalilinux/build-scripts/live-build-config/-/raw/master/kali-config/common/includes.installer/kali-finish-install?ref_type=heads
        chmod a+x cdrom/simple-cdd/kali.postinst
    fi

    if [ "$distro" = debian ] && is_debian_eol; then
        curl -Lo usr/share/keyrings/debian-archive-keyring.gpg https://deb.freexian.com/extended-lts/archive-key.gpg
    fi

    # 提前下载 fdisk
    # 因为 fdisk-udeb 包含 fdisk 和 sfdisk，提前下载可减少占用
    mkdir_clear $tmp/fdisk
    download_and_extract_udeb fdisk-udeb $tmp/fdisk
    cp -f $tmp/fdisk/usr/sbin/fdisk usr/sbin/

    # >256M 或者当前系统是 windows
    if [ $ram_size -gt 256 ] || is_in_windows; then
        sed -i '/^pata-modules/d' $net_retriever
        sed -i '/^sata-modules/d' $net_retriever
        sed -i '/^scsi-modules/d' $net_retriever
    else
        # <=256M 极限优化
        find_main_disk
        extra_drivers=
        for driver in $(get_disk_drivers $xda); do
            echo "using driver: $driver"
            case $driver in
            nvme) extra_drivers+=" nvme nvme-core" ;;
                # xen 的横杠特别不同
            xen_blkfront) extra_drivers+=" xen-blkfront" ;;
            xen_scsifront) extra_drivers+=" xen-scsifront" ;;
            virtio_blk | virtio_scsi | hv_storvsc | vmw_pvscsi) extra_drivers+=" $driver" ;;
            pata_legacy) sed -i '/^pata-modules/d' $net_retriever ;; # 属于 pata-modules
            ata_piix) sed -i '/^sata-modules/d' $net_retriever ;;    # 属于 sata-modules
            ata_generic) ;;                                          # 属于 ata-modules，不用处理，因为我们设置强制安装了 ata-modules
            esac
        done

        # extra drivers
        # xen 还需要以下两个？
        # kernel/drivers/xen/xen-scsiback.ko
        # kernel/drivers/block/xen-blkback/xen-blkback.ko
        # 但反查也找不到 curl https://deb.debian.org/debian/dists/bookworm/main/Contents-udeb-amd64.gz | zcat | grep xen
        if [ -n "$extra_drivers" ]; then
            mkdir_clear $tmp/scsi
            download_and_extract_udeb scsi-modules-$kver-di $tmp/scsi
            relative_drivers_dir=lib/modules/$kver/kernel/drivers

            udeb_drivers_dir=$tmp/scsi/$relative_drivers_dir
            dist_drivers_dir=$initrd_dir/$relative_drivers_dir
            (
                cd $udeb_drivers_dir
                for driver in $extra_drivers; do
                    # debian 模块没有压缩
                    # kali 模块有压缩
                    # 因此要有 *
                    if ! find $dist_drivers_dir -name "$driver.ko*" | grep -q .; then
                        echo "adding driver: $driver"
                        file=$(find . -name "$driver.ko*" | grep .)
                        cp -fv --parents "$file" "$dist_drivers_dir"
                    fi
                done
            )
        fi
    fi

    # amd64)
    # 	level1=737 # MT=754108, qemu: -m 780
    # 	level2=424 # MT=433340, qemu: -m 460
    # 	min=316    # MT=322748, qemu: -m 350

    # 将 use_level 2 9 修改为 use_level 1
    # x86 use_level 2 会出现 No root file system is defined.
    # arm 即使 use_level 1 也会出现 No root file system is defined.
    sed -i 's/use_level=[29]/use_level=1/' lib/debian-installer-startup.d/S15lowmem

    # hack 3
    # 修改 trans.sh
    # 1. 直接调用 create_ifupdown_config
    insert_into_file $initrd_dir/trans.sh after ': main' <<EOF
        distro=$nextos_distro
        create_ifupdown_config /etc/network/interfaces
        exit
EOF
    # 2. 删除 debian busybox 无法识别的语法
    # 3. 删除 apk 语句
    # 4. debian 11/12 initrd 无法识别 > >
    # 5. debian 11/12 initrd 无法识别 < <
    # 6. debian 11 initrd 无法识别 set -E
    # 7. debian 11 initrd 无法识别 trap ERR
    # 删除或注释，可能会导致空方法而报错，因此改为替换成'\n: #'
    replace='\n: #'
    sed -Ei "s/> >/$replace/" $initrd_dir/trans.sh
    sed -Ei "s/< </$replace/" $initrd_dir/trans.sh
    sed -Ei "s/(^[[:space:]]*set[[:space:]].*)E/\1/" $initrd_dir/trans.sh
    sed -Ei "s/^[[:space:]]*apk[[:space:]]/$replace/" $initrd_dir/trans.sh
    sed -Ei "s/^[[:space:]]*trap[[:space:]]/$replace/" $initrd_dir/trans.sh
}

get_disk_drivers() {
    get_drivers "/sys/block/$1"
}

get_net_drivers() {
    get_drivers "/sys/class/net/$1"
}

# 不用在 windows 判断是哪种硬盘/网络驱动，因为 256M 运行 windows 只可能是 xp，而脚本本来就不支持 xp
# 而且安装过程也有二次判断
get_drivers() {
    # 有以下结果组合出现
    # sd_mod
    # virtio_blk
    # virtio_scsi
    # virtio_pci
    # pcieport
    # xen_blkfront
    # ahci
    # nvme
    # mptspi
    # mptsas
    # vmw_pvscsi
    (
        cd "$(readlink -f $1)"
        while ! [ "$(pwd)" = / ]; do
            if [ -d driver ]; then
                if [ -d driver/module ]; then
                    # 显示全名，例如 xen_blkfront sd_mod
                    # 但 ahci 没有这个文件，所以 else 不能省略
                    basename "$(readlink -f driver/module)"
                else
                    # 不显示全名，例如 vbd sd
                    basename "$(readlink -f driver)"
                fi
            fi
            cd ..
        done
    )
}

exit_if_cant_use_cloud_kernel() {
    find_main_disk
    collect_netconf

    # shellcheck disable=SC2154
    if ! can_use_cloud_kernel "$xda" $ipv4_ethx $ipv6_ethx; then
        error_and_exit "Can't use cloud kernel. And not enough RAM to run normal kernel."
    fi
}

can_use_cloud_kernel() {
    # initrd 下也要使用，不要用 <<<

    # 有些虚拟机用了 ahci，但云内核没有 ahci 驱动
    cloud_eth_modules='ena|gve|mana|virtio_net|xen_netfront|hv_netvsc|vmxnet3|mlx4_en|mlx4_core|mlx5_core|ixgbevf'
    cloud_blk_modules='ata_generic|ata_piix|pata_legacy|nvme|virtio_blk|virtio_scsi|xen_blkfront|xen_scsifront|hv_storvsc|vmw_pvscsi'

    # disk
    drivers="$(get_disk_drivers $1)"
    shift
    for driver in $drivers; do
        echo "using disk driver: $driver"
    done
    echo "$drivers" | grep -Ewq "$cloud_blk_modules" || return 1

    # net
    # v4 v6 eth 相同，只检查一次
    if [ "$1" = "$2" ]; then
        shift
    fi
    while [ $# -gt 0 ]; do
        drivers="$(get_net_drivers $1)"
        shift
        for driver in $drivers; do
            echo "using net driver: $driver"
        done
        echo "$drivers" | grep -Ewq "$cloud_eth_modules" || return 1
    done
}

create_can_use_cloud_kernel_sh() {
    cat <<EOF >$1
        $(get_function get_drivers)
        $(get_function get_net_drivers)
        $(get_function get_disk_drivers)
        $(get_function can_use_cloud_kernel)

        can_use_cloud_kernel "\$@"
EOF
}

get_ip_conf_cmd() {
    collect_netconf >&2
    is_in_china && is_in_china=true || is_in_china=false

    sh=/alpine-network.sh
    if is_found_ipv4_netconf && is_found_ipv6_netconf && [ "$ipv4_mac" = "$ipv6_mac" ]; then
        echo "'$sh' '$ipv4_mac' '$ipv4_addr' '$ipv4_gateway' '$ipv6_addr' '$ipv6_gateway' '$is_in_china'"
    else
        if is_found_ipv4_netconf; then
            echo "'$sh' '$ipv4_mac' '$ipv4_addr' '$ipv4_gateway' '' '' '$is_in_china'"
        fi
        if is_found_ipv6_netconf; then
            echo "'$sh' '$ipv6_mac' '' '' '$ipv6_addr' '$ipv6_gateway' '$is_in_china'"
        fi
    fi
}

mod_initrd_alpine() {
    # hack 1 v3.19 和之前的 virt 内核需添加 ipv6 模块
    if virt_dir=$(ls -d $initrd_dir/lib/modules/*-virt 2>/dev/null); then
        ipv6_dir=$virt_dir/kernel/net/ipv6
        if ! [ -f $ipv6_dir/ipv6.ko ] && ! grep -q ipv6 $initrd_dir/lib/modules/*/modules.builtin; then
            mkdir -p $ipv6_dir
            modloop_file=$tmp/modloop_file
            modloop_dir=$tmp/modloop_dir
            curl -Lo $modloop_file $nextos_modloop
            if is_in_windows; then
                # cygwin 没有 unsquashfs
                7z e $modloop_file ipv6.ko -r -y -o$ipv6_dir
            else
                install_pkg unsquashfs
                mkdir_clear $modloop_dir
                unsquashfs -f -d $modloop_dir $modloop_file 'modules/*/kernel/net/ipv6/ipv6.ko'
                find $modloop_dir -name ipv6.ko -exec cp {} $ipv6_dir/ \;
            fi
        fi
    fi

    # hack 2 /usr/share/udhcpc/default.script
    # 脚本被调用的顺序
    # udhcpc:  deconfig
    # udhcpc:  bound
    # udhcpc6: deconfig
    # udhcpc6: bound
    # shellcheck disable=SC2317
    udhcpc() {
        if [ "$1" = deconfig ]; then
            return
        fi
        if [ "$1" = bound ] && [ -n "$ipv6" ]; then
            # shellcheck disable=SC2154
            ip -6 addr add "$ipv6" dev "$interface"
            ip link set dev "$interface" up
            return
        fi
    }

    get_function_content udhcpc |
        insert_into_file usr/share/udhcpc/default.script after 'deconfig\|renew\|bound'

    # 允许设置 ipv4 onlink 网关
    sed -Ei 's,(0\.0\.0\.0\/0),"\1 onlink",' usr/share/udhcpc/default.script

    # hack 3 网络配置
    # alpine 根据 MAC_ADDRESS 判断是否有网络
    # https://github.com/alpinelinux/mkinitfs/blob/c4c0115f9aa5aa8884c923dc795b2638711bdf5c/initramfs-init.in#L914
    insert_into_file init after 'configure_ip\(\)' <<EOF
        depmod
        [ -d /sys/module/ipv6 ] || modprobe ipv6
        $(get_ip_conf_cmd)
        MAC_ADDRESS=1
        return
EOF

    # grep -E -A5 'configure_ip\(\)' init

    # hack 4 运行 trans.start
    # exec /bin/busybox switch_root $switch_root_opts $sysroot $chart_init "$KOPT_init" $KOPT_init_args # 3.17
    # exec              switch_root $switch_root_opts $sysroot $chart_init "$KOPT_init" $KOPT_init_args # 3.18
    # 1. alpine arm initramfs 时间问题 要添加 --no-check-certificate
    # 2. aws t4g arm 如果没设置console=ttyx，在initramfs里面wget https会出现bad header错误，chroot后正常
    # Connecting to raw.githubusercontent.com (185.199.108.133:443)
    # 60C0BB2FFAFF0000:error:0A00009C:SSL routines:ssl3_get_record:http request:ssl/record/ssl3_record.c:345:
    # ssl_client: SSL_connect
    # wget: bad header line: �
    insert_into_file init before '^exec (/bin/busybox )?switch_root' <<EOF
        # echo "wget --no-check-certificate -O- $confhome/trans.sh | /bin/ash" >\$sysroot/etc/local.d/trans.start
        # wget --no-check-certificate -O \$sysroot/etc/local.d/trans.start $confhome/trans.sh
        cp /trans.sh \$sysroot/etc/local.d/trans.start
        chmod a+x \$sysroot/etc/local.d/trans.start
        ln -s /etc/init.d/local \$sysroot/etc/runlevels/default/
EOF

    # 判断云镜像 debain 能否用云内核
    if is_distro_like_debian; then
        create_can_use_cloud_kernel_sh can_use_cloud_kernel.sh
        insert_into_file init before '^exec (/bin/busybox )?switch_root' <<EOF
        cp /can_use_cloud_kernel.sh \$sysroot/
        chmod a+x \$sysroot/can_use_cloud_kernel.sh
EOF
    fi
}

mod_initrd() {
    info "mod $nextos_distro initrd"
    install_pkg gzip cpio

    # 解压
    # 先删除临时文件，避免之前运行中断有残留文件
    initrd_dir=$tmp/initrd
    mkdir_clear $initrd_dir
    cd $initrd_dir

    # cygwin 下处理 debian initrd 时
    # 解压/重新打包/删除 initrd 的 /dev/console /dev/null 都会报错
    # cpio: dev/console: Cannot utime: Invalid argument
    # cpio: ./dev/console: Cannot stat: Bad address
    # 用 windows 文件管理器可删除

    # 但同样运行 zcat /reinstall-initrd | cpio -idm
    # 打开 C:\cygwin\Cygwin.bat ，运行报错
    # 打开桌面的 Cygwin 图标，运行就没问题

    # shellcheck disable=SC2046
    # nonmatching 是精确匹配路径
    zcat /reinstall-initrd | cpio -idm \
        $(is_in_windows && echo --nonmatching 'dev/console' --nonmatching 'dev/null')

    curl -Lo $initrd_dir/trans.sh $confhome/trans.sh
    if ! grep -i "$SCRIPT_VERSION" $initrd_dir/trans.sh; then
        error_and_exit "
This script is outdated, please download reinstall.sh again.
脚本有更新，请重新下载 reinstall.sh"
    fi
    curl -Lo $initrd_dir/alpine-network.sh $confhome/alpine-network.sh
    chmod a+x $initrd_dir/trans.sh $initrd_dir/alpine-network.sh

    if is_distro_like_debian $nextos_distro; then
        mod_initrd_debian_kali
    else
        mod_initrd_$nextos_distro
    fi

    # alpine live 不精简 initrd
    # 因为不知道用户想干什么，可能会用到精简的文件
    if is_virt && ! is_alpine_live; then
        remove_useless_initrd_files
    fi

    # 重建
    # 注意要用 cpio -H newc 不要用 cpio -c ，不同版本的 -c 作用不一样，很坑
    # -c    Use the old portable (ASCII) archive format
    # -c    Identical to "-H newc", use the new (SVR4)
    #       portable format.If you wish the old portable
    #       (ASCII) archive format, use "-H odc" instead.
    find . | cpio --quiet -o -H newc | gzip -1 >/reinstall-initrd
    cd - >/dev/null
}

remove_useless_initrd_files() {
    # 显示精简前的大小
    du -sh .

    # 删除 initrd 里面没用的文件/驱动
    rm -rf bin/brltty
    rm -rf etc/brltty
    rm -rf sbin/wpa_supplicant
    rm -rf usr/lib/libasound.so.*
    rm -rf usr/share/alsa
    (
        cd lib/modules/*/kernel/drivers/net/ethernet/
        for item in *; do
            case "$item" in
            intel | amazon | google) ;;
            *) rm -rf $item ;;
            esac
        done
    )
    (
        cd lib/modules/*/kernel
        for item in \
            net/mac80211 \
            net/wireless \
            net/bluetooth \
            drivers/hid \
            drivers/mmc \
            drivers/mtd \
            drivers/usb \
            drivers/ssb \
            drivers/mfd \
            drivers/bcma \
            drivers/pcmcia \
            drivers/parport \
            drivers/platform \
            drivers/staging \
            drivers/net/usb \
            drivers/net/bonding \
            drivers/net/wireless \
            drivers/input/rmi4 \
            drivers/input/keyboard \
            drivers/input/touchscreen \
            drivers/bus/mhi \
            drivers/char/pcmcia \
            drivers/misc/cardreader; do
            rm -rf $item
        done
    )

    # 显示精简后的大小
    du -sh .
}

# 脚本入口
if is_in_windows; then
    # win系统盘
    c=$(echo $SYSTEMDRIVE | cut -c1)

    # 64位系统 + 32位cmd/cygwin，需要添加 PATH，否则找不到64位系统程序，例如bcdedit
    sysnative=$(cygpath -u $WINDIR\\Sysnative)
    if [ -d $sysnative ]; then
        PATH=$PATH:$sysnative
    fi

    # 更改 windows 命令输出语言为英文
    # chcp 会清屏
    mode.com con cp select=437 >/dev/null
fi

# 检查 root
if is_in_windows; then
    # 64位系统 + 32位cmd/cygwin，运行 openfiles 报错：目标系统必须运行 32 位的操作系统
    if ! fltmc >/dev/null 2>&1; then
        error_and_exit "Please run as administrator."
    fi
else
    if [ "$EUID" -ne 0 ]; then
        error_and_exit "Please run as root."
    fi
fi

# 整理参数
if ! opts=$(getopt -n $0 -o "" --long ci,installer,debug,minimal,hold:,sleep:,iso:,image-name:,img:,lang:,commit:,force: -- "$@"); then
    usage_and_exit
fi

eval set -- "$opts"
# shellcheck disable=SC2034
while true; do
    case "$1" in
    --commit)
        commit=$2
        shift 2
        ;;
    --debug)
        set -x
        shift
        ;;
    --ci)
        cloud_image=1
        unset installer
        shift
        ;;
    --installer)
        installer=1
        unset cloud_image
        shift
        ;;
    --minimal)
        minimal=1
        shift
        ;;
    --hold | --sleep)
        hold=$2
        if ! { [ "$hold" = 1 ] || [ "$hold" = 2 ]; }; then
            error_and_exit "Invalid --hold value: $hold."
        fi
        shift 2
        ;;
    --force)
        force=$2
        if ! { [ "$force" = bios ] || [ "$force" = efi ]; }; then
            error_and_exit "Invalid --force value: $force."
        fi
        shift 2
        ;;
    --img)
        img=$2
        shift 2
        ;;
    --iso)
        iso=$2
        shift 2
        ;;
    --image-name)
        image_name=$(echo "$2" | to_lower)
        shift 2
        ;;
    --lang)
        lang=$(echo "$2" | to_lower)
        shift 2
        ;;
    --)
        shift
        break
        ;;
    *)
        echo "Unexpected option: $1."
        usage_and_exit
        ;;
    esac
done

# 检查目标系统名
verify_os_name "$@"

# 检查必须的参数
verify_os_args

# 不支持容器虚拟化
assert_not_in_container

# 不支持安全启动
if is_secure_boot_enabled; then
    error_and_exit "Please disable secure boot first."
fi

# 必备组件
install_pkg curl grep

# /tmp 挂载在内存的话，可能不够空间
tmp=/reinstall-tmp
mkdir_clear "$tmp"

# 强制忽略/强制添加 --ci 参数
# debian 不强制忽略 ci 留作测试
case "$distro" in
dd | windows | netboot.xyz | kali | alpine | arch | gentoo | nixos)
    if is_use_cloud_image; then
        echo "ignored --ci"
        unset cloud_image
    fi
    ;;
oracle | opensuse | anolis | opencloudos | openeuler)
    cloud_image=1
    ;;
redhat | centos | alma | rocky | fedora | ubuntu)
    if is_force_use_installer; then
        unset cloud_image
    else
        cloud_image=1
    fi
    ;;
esac

# 检查内存
check_ram

# 检查硬件架构
if is_in_windows; then
    # x86-based PC
    # x64-based PC
    # ARM-based PC
    # ARM64-based PC
    basearch=$(wmic ComputerSystem get SystemType /format:list |
        grep '=' | cut -d= -f2 | cut -d- -f1)
else
    # archlinux 云镜像没有 arch 命令
    # https://en.wikipedia.org/wiki/Uname
    basearch=$(uname -m)
fi

# 统一架构名称，并强制 64 位
case "$(echo $basearch | to_lower)" in
i?86 | x64 | x86* | amd64)
    basearch=x86_64
    basearch_alt=amd64
    ;;
arm* | aarch64)
    basearch=aarch64
    basearch_alt=arm64
    ;;
*) error_and_exit "Unsupported arch: $basearch" ;;
esac

# 未测试
if false && [[ "$confhome" = http*://raw.githubusercontent.com/* ]]; then
    repo=$(echo $confhome | cut -d/ -f4,5)
    branch=$(echo $confhome | cut -d/ -f6)
    # 避免脚本更新时，文件不同步造成错误
    if [ -z "$commit" ]; then
        commit=$(curl -L https://api.github.com/repos/$repo/git/refs/heads/$branch |
            grep '"sha"' | grep -Eo '[0-9a-f]{40}')
    fi
    # shellcheck disable=SC2001
    confhome=$(echo "$confhome" | sed "s/main$/$commit/")
fi

# 设置国内代理
# gitee 不支持ipv6
# jsdelivr 有12小时缓存
# https://github.com/XIU2/UserScript/blob/master/GithubEnhanced-High-Speed-Download.user.js#L31
if is_in_china; then
    if [ -n "$confhome_cn" ]; then
        confhome=$confhome_cn
    elif [ -n "$github_proxy" ] && [[ "$confhome" = http*://raw.githubusercontent.com/* ]]; then
        confhome=${confhome/http:\/\//https:\/\/}
        confhome=${confhome/https:\/\/raw.githubusercontent.com/$github_proxy}
    fi
fi

# 以下目标系统不需要两步安装
# alpine
# debian
# el7 x86_64 >=1g
# el7 aarch64 >=1.5g
# el8/9/fedora 任何架构 >=2g
if is_netboot_xyz ||
    { ! is_use_cloud_image && {
        [ "$distro" = "alpine" ] || is_distro_like_debian ||
            { is_distro_like_redhat && [ $releasever -eq 7 ] && [ $ram_size -ge 1024 ] && [ $basearch = "x86_64" ]; } ||
            { is_distro_like_redhat && [ $releasever -eq 7 ] && [ $ram_size -ge 1536 ] && [ $basearch = "aarch64" ]; } ||
            { is_distro_like_redhat && [ $releasever -ge 8 ] && [ $ram_size -ge 2048 ]; }
    }; }; then
    setos nextos $distro $releasever
else
    # alpine 作为中间系统时，使用 3.20
    alpine_ver_for_trans=3.20
    setos finalos $distro $releasever
    setos nextos alpine $alpine_ver_for_trans
fi

# 删除之前的条目
# 防止第一次运行 netboot.xyz，第二次运行其他，但还是进入 netboot.xyz
# 防止第一次运行其他，第二次运行 netboot.xyz，但还有第一次的菜单
# bios 无论什么情况都用到 grub，所以不用处理
if is_efi; then
    if is_in_windows; then
        rm -f /cygdrive/$c/grub.cfg

        bcdedit /set '{fwbootmgr}' bootsequence '{bootmgr}'
        bcdedit /enum bootmgr | grep --text -B3 'reinstall' | awk '{print $2}' | grep '{.*}' |
            xargs -I {} cmd /c bcdedit /delete {}
    else
        # shellcheck disable=SC2046
        # 如果 nixos 的 efi 挂载到 /efi，则不会生成 /boot 文件夹
        # find 不存在的路径会报错退出
        find $(get_maybe_efi_dirs_in_linux) $([ -d /boot ] && echo /boot) \
            -type f -name 'custom.cfg' -exec rm -f {} \;

        install_pkg efibootmgr
        efibootmgr | grep -q 'BootNext:' && efibootmgr --quiet --delete-bootnext
        efibootmgr | grep_efi_entry | grep 'reinstall' | grep_efi_index |
            xargs -I {} efibootmgr --quiet --bootnum {} --delete-bootnum
    fi
fi

# 有的机器开启了 kexec，例如腾讯云轻量 debian，要禁用
if ! is_in_windows && [ -f /etc/default/kexec ]; then
    sed -i 's/LOAD_KEXEC=true/LOAD_KEXEC=false/' /etc/default/kexec
fi

# 下载 netboot.xyz / 内核
# shellcheck disable=SC2154
if is_netboot_xyz; then
    if is_efi; then
        curl -Lo /netboot.xyz.efi $nextos_efi
        if is_in_windows; then
            add_efi_entry_in_windows /netboot.xyz.efi
        else
            add_efi_entry_in_linux /netboot.xyz.efi
        fi
    else
        curl -Lo /reinstall-vmlinuz $nextos_vmlinuz
    fi
else
    # 下载 nextos 内核
    info download vmlnuz and initrd
    curl -Lo /reinstall-vmlinuz $nextos_vmlinuz
    curl -Lo /reinstall-initrd $nextos_initrd
    if is_use_firmware; then
        curl -Lo /reinstall-firmware $nextos_firmware
    fi
fi

# 修改 alpine debian kali initrd
if [ "$nextos_distro" = alpine ] || is_distro_like_debian "$nextos_distro"; then
    mod_initrd
fi

# 将内核/netboot.xyz.lkrn 放到正确的位置
if false && is_need_grub_extlinux; then
    if is_in_windows; then
        cp -f /reinstall-vmlinuz /cygdrive/$c/
        is_have_initrd && cp -f /reinstall-initrd /cygdrive/$c/
    else
        if is_os_in_btrfs && is_os_in_subvol; then
            cp_to_btrfs_root /reinstall-vmlinuz
            is_have_initrd && cp_to_btrfs_root /reinstall-initrd
        fi
    fi
fi

# grub / extlinux
if is_need_grub_extlinux; then
    # win 使用外部 grub
    if is_in_windows; then
        install_grub_win
    else
        # linux aarch64 原系统的 grub 可能无法启动 alpine 3.19 的内核
        # 要用去除了内核 magic number 校验的 grub
        # 为了方便测试，linux x86 efi 也采用外部 grub
        if is_efi; then
            install_grub_linux_efi
        fi
    fi

    # 寻找 grub.cfg / extlinux.conf
    if is_in_windows; then
        if is_efi; then
            grub_cfg=/cygdrive/$c/grub.cfg
        else
            grub_cfg=/cygdrive/$c/grub/grub.cfg
        fi
    else
        # linux
        if is_efi; then
            # 现在 linux-efi 是使用 reinstall 目录下的 grub
            # shellcheck disable=SC2046
            efi_reinstall_dir=$(find $(get_maybe_efi_dirs_in_linux) -type d -name "reinstall" | head -1)
            grub_cfg=$efi_reinstall_dir/grub.cfg
        else
            if is_mbr_using_grub; then
                if is_have_cmd update-grub; then
                    # alpine debian ubuntu
                    grub_cfg=$(grep -o '[^ ]*grub.cfg' "$(get_cmd_path update-grub)" | head -1)
                else
                    # 找出主配置文件（含有menuentry|blscfg）
                    # 现在 efi 用下载的 grub，因此不需要查找 efi 目录
                    grub_cfg=$(find_grub_extlinux_cfg '/boot/grub*' grub.cfg 'menuentry|blscfg')
                fi
            else
                # extlinux
                extlinux_cfg=$(find_grub_extlinux_cfg /boot extlinux.conf LINUX)
            fi
        fi
    fi

    # 判断用 linux 还是 linuxefi（主要是红帽系）
    # 现在 efi 用下载的 grub，因此不需要判断 linux 或 linuxefi
    if false && is_use_local_grub_extlinux; then
        # 在x86 efi机器上，不同版本的 grub 可能用 linux 或 linuxefi 加载内核
        # 通过检测原有的条目有没有 linuxefi 字样就知道当前 grub 用哪一种
        # 也可以检测 /etc/grub.d/10_linux
        if [ -d /boot/loader/entries/ ]; then
            entries="/boot/loader/entries/"
        fi
        if grep -q -r -E '^[[:space:]]*linuxefi[[:space:]]' $grub_cfg $entries; then
            efi=efi
        fi
    fi

    # 找到 grub 程序的前缀
    # 并重新生成 grub.cfg
    # 因为有些机子例如hython debian的grub.cfg少了40_custom 41_custom
    if is_use_local_grub; then
        if is_have_cmd grub2-mkconfig; then
            grub=grub2
        elif is_have_cmd grub-mkconfig; then
            grub=grub
        else
            error_and_exit "grub not found"
        fi

        # nixos 手动执行 grub-mkconfig -o /boot/grub/grub.cfg 会丢失系统启动条目
        # 正确的方法是修改 configuration.nix 的 boot.loader.grub.extraEntries
        # 但是修改 configuration.nix 不是很好，因此改成修改 grub.cfg
        if [ -x /nix/var/nix/profiles/system/bin/switch-to-configuration ]; then
            # 生成 grub.cfg
            /nix/var/nix/profiles/system/bin/switch-to-configuration boot
            # 手动启用 41_custom
            nixos_grub_home="$(dirname "$(readlink -f "$(get_cmd_path grub-mkconfig)")")/.."
            $nixos_grub_home/etc/grub.d/41_custom >>$grub_cfg
        elif is_have_cmd update-grub; then
            update-grub
        else
            $grub-mkconfig -o $grub_cfg
        fi
    fi

    # 重新生成 extlinux.conf
    if is_use_local_extlinux; then
        if is_have_cmd update-extlinux; then
            update-extlinux
        fi
    fi

    # 选择用 custom.cfg (linux-bios) 还是 grub.cfg (linux-efi / win)
    if is_use_local_grub; then
        target_cfg=$(dirname $grub_cfg)/custom.cfg
    else
        target_cfg=$grub_cfg
    fi

    # 找到 /reinstall-vmlinuz /reinstall-initrd 的绝对路径
    if is_in_windows; then
        # dir=/cygwin/
        dir=$(cygpath -m / | cut -d: -f2-)/
    else
        # extlinux + 单独的 boot 分区
        # 把内核文件放在 extlinux.conf 所在的目录
        if is_use_local_extlinux && is_boot_in_separate_partition; then
            dir=
        else
            # 获取当前系统根目录在 btrfs 中的绝对路径
            if is_os_in_btrfs; then
                # btrfs subvolume show /
                # 输出可能是 / 或 root 或 @/.snapshots/1/snapshot
                dir=$(btrfs subvolume show / | head -1)
                if ! [ "$dir" = / ]; then
                    dir="/$dir/"
                fi
            else
                dir=/
            fi
        fi
    fi

    vmlinuz=${dir}reinstall-vmlinuz
    initrd=${dir}reinstall-initrd
    firmware=${dir}reinstall-firmware

    # 设置 linux initrd 命令
    if is_use_local_extlinux; then
        linux_cmd=LINUX
        initrd_cmd=INITRD
    else
        if is_netboot_xyz; then
            linux_cmd=linux16
            initrd_cmd=initrd16
        else
            linux_cmd="linux$efi"
            initrd_cmd="initrd$efi"
        fi
    fi

    # 设置 cmdlind initrds
    if ! is_netboot_xyz; then
        find_main_disk
        build_cmdline

        initrds="$initrd"
        if is_use_firmware; then
            initrds+=" $firmware"
        fi
    fi

    if is_use_local_extlinux; then
        info extlinux
        echo $extlinux_cfg
        extlinux_dir="$(dirname $extlinux_cfg)"

        # 不起作用
        # 好像跟 extlinux --once 有冲突
        sed -i "/^MENU HIDDEN/d" $extlinux_cfg
        sed -i "/^TIMEOUT /d" $extlinux_cfg

        del_empty_lines <<EOF | tee -a $extlinux_cfg
TIMEOUT 5
LABEL reinstall
  MENU LABEL $(get_entry_name)
  $linux_cmd $vmlinuz
  $([ -n "$initrds" ] && echo "$initrd_cmd $initrds")
  $([ -n "$cmdline" ] && echo "APPEND $cmdline")
EOF
        # 设置重启引导项
        extlinux --once=reinstall $extlinux_dir

        # 复制文件到 extlinux 工作目录
        if is_boot_in_separate_partition; then
            info "copying files to $extlinux_dir"
            is_have_initrd && cp -f /reinstall-initrd $extlinux_dir
            is_use_firmware && cp -f /reinstall-firmware $extlinux_dir
            # 放最后，防止前两条返回非 0 而报错
            cp -f /reinstall-vmlinuz $extlinux_dir
        fi
    else
        # cloudcone 从光驱的 grub 启动，再加载硬盘的 grub.cfg
        # menuentry "Grub 2" --id grub2 {
        #         set root=(hd0,msdos1)
        #         configfile /boot/grub2/grub.cfg
        # }

        # 加载后 $prefix 依然是光驱的 (hd96)/boot/grub
        # 导致找不到 $prefix 目录的 grubenv，因此读取不到 next_entry
        # 以下方法为 cloudcone 重新加载 grubenv

        # 需查找 2*2 个文件夹
        # 分区：系统 / boot
        # 文件夹：grub / grub2
        # shellcheck disable=SC2121,SC2154
        # cloudcone debian 能用但 ubuntu 模板用不了
        # ubuntu 模板甚至没显示 reinstall menuentry
        load_grubenv_if_not_loaded() {
            if ! [ -s $prefix/grubenv ]; then
                for dir in /boot/grub /boot/grub2 /grub /grub2; do
                    set grubenv="($root)$dir/grubenv"
                    if [ -s $grubenv ]; then
                        load_env --file $grubenv
                        if [ "${next_entry}" ]; then
                            set default="${next_entry}"
                            set next_entry=
                            save_env --file $grubenv next_entry
                        else
                            set default="0"
                        fi
                        return
                    fi
                done
            fi
        }

        # 生成 grub 配置
        # 实测 centos 7 lvm 要手动加载 lvm 模块
        info grub
        echo $target_cfg

        get_function_content load_grubenv_if_not_loaded >$target_cfg

        # 原系统为 openeuler 云镜像，需要添加 --unrestricted，否则要输入密码
        del_empty_lines <<EOF | tee -a $target_cfg
set timeout_style=menu
set timeout=5
menuentry "$(get_entry_name)" --unrestricted {
    $(! is_in_windows && echo 'insmod lvm')
    $(is_os_in_btrfs && echo 'set btrfs_relative_path=n')
    insmod all_video
    search --no-floppy --file --set=root $vmlinuz
    $linux_cmd $vmlinuz $cmdline
    $([ -n "$initrds" ] && echo "$initrd_cmd $initrds")
}
EOF

        # 设置重启引导项
        if is_use_local_grub; then
            $grub-reboot "$(get_entry_name)"
        fi
    fi
fi

info 'info'
echo "$distro $releasever"

if ! { is_netboot_xyz || is_use_dd; }; then
    if [ "$distro" = windows ]; then
        username="administrator"
    else
        username="root"
    fi
    echo "Username: $username"
    echo "Password: 123@@@"
fi

if is_netboot_xyz; then
    echo 'Reboot to start netboot.xyz.'
elif is_alpine_live; then
    echo 'Reboot to start Alpine Live OS.'
elif is_use_dd; then
    echo 'Reboot to start DD.'
else
    echo "Reboot to start the installation."
fi

if is_in_windows; then
    echo 'You can run this command to reboot:'
    echo 'shutdown /r /t 0'
fi
