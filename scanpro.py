#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
Dr.COM 校园网白名单自动化嗅探探针 (Whitelist Prober) 增强版
新增大量国内/教育/CDN/IPv6 测试站点，全面绘制免流白名单地图。
"""

import socket
import requests
import urllib3
from concurrent.futures import ThreadPoolExecutor
import threading

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)
print_lock = threading.Lock()

# ================= 探测目标字典（大幅扩充） =================
TARGET_DOMAINS = [
    # ---------- 腾讯系 ----------
    "cloud.tencent.com",
    "www.qq.com",
    "weixin.qq.com",
    "www.tencent.com",
    "qlogo.cn",                # 腾讯 CDN 图片域名

    # ---------- 阿里系 ----------
    "aliyun.com",
    "www.taobao.com",
    "www.alipay.com",
    "img.alicdn.com",          # 阿里 CDN

    # ---------- 百度系 ----------
    "ipv6.baidu.com",
    "www.baidu.com",
    "pan.baidu.com",

    # ---------- 字节跳动 ----------
    "www.douyin.com",
    "www.toutiao.com",
    "lf3-cdn-tos.bytecdntp.com", # 字节 CDN

    # ---------- 京东/拼多多/美团 ----------
    "www.jd.com",
    "www.pinduoduo.com",
    "www.meituan.com",

    # ---------- 新浪/网易/搜狐 ----------
    "www.sina.com.cn",
    "www.163.com",
    "www.sohu.com",

    # ---------- B站 / A站 ----------
    "www.bilibili.com",
    "www.acfun.cn",
    "api.bilibili.com",        # B站 API

    # ---------- 教育网 / CERNET2 ----------
    "bt.byr.cn",               # 北邮人 PT
    "ipv6.tsinghua.edu.cn",    # 清华 IPv6
    "ipv6.pku.edu.cn",         # 北大 IPv6
    "www.ipv6.zju.edu.cn",     # 浙大 IPv6

    # ---------- 大型 CDN 与云服务 ----------
    "www.cloudflare.com",
    "1.1.1.1",                 # Cloudflare DNS
    "8.8.8.8",                 # Google DNS
    "dns.alidns.com",          # 阿里 DNS
    "cdn.jsdelivr.net",        # 国际 CDN，教育网常用

    # ---------- 国际大厂 ----------
    "www.apple.com",
    "captive.apple.com",       # Apple 网络探针
    "www.microsoft.com",
    "www.github.com",
    "github.githubassets.com", # GitHub 静态资源
    "raw.githubusercontent.com",

    # ---------- 游戏/直播 ----------
    "www.douyu.com",
    "www.huya.com",
    "www.steampowered.com",    # Steam 商店
    "api.steampowered.com",

    # ---------- 快递/出行 ----------
    "www.sf-express.com",
    "www.didi.com",

    # ---------- 其他 IPv6 测试 ----------
    "test-ipv6.com",
    "ipv6-test.com",
    "mirrors6.tuna.tsinghua.edu.cn",  # 清华 IPv6 镜像站
    "mirrors.ustc.edu.cn",            # 中科大镜像站
]
# ============================================================


def check_dns(domain):
    try:
        addr_info = socket.getaddrinfo(domain, None)
        ips = list(set([info[4][0] for info in addr_info]))
        has_v6 = any(':' in ip for ip in ips)
        return ips, has_v6
    except Exception:
        return [], False


def probe_url(url):
    try:
        resp = requests.get(url, timeout=5, allow_redirects=False, verify=True)
        status = resp.status_code

        if status == 200:
            if "Dr.COM" in resp.text or "bistu.edu.cn" in resp.text:
                return "🔴 被劫持", "返回 200，但内容被篡改为认证页"
            return "🟢 绝对畅通", f"直连目标服务器 (HTTP {status})"

        elif status in (301, 302, 307):
            location = resp.headers.get('Location', '')
            if "bistu.edu.cn" in location or "Dr.COM" in location:
                return "🔴 302拦截", f"网关踢至认证页: {location[:50]}"
            return "🟢 正常跳转", f"目标服务器自身跳转 -> {location[:50]}"

        else:
            return "🟢 绝对畅通", f"目标服务器返回 HTTP {status}"

    except requests.exceptions.SSLError:
        return "🟡 证书劫持", "证书不匹配，网关 MITM 拦截"
    except requests.exceptions.ConnectTimeout:
        return "⚫ 丢包超时", "请求被丢弃 (Drop)"
    except requests.exceptions.ReadTimeout:
        return "⚫ 读取超时", "连接建立但沉默丢弃 (Silent Drop)"
    except requests.exceptions.ConnectionError:
        return "⚫ 连接重置", "TCP 连接被 RST 重置"
    except Exception as e:
        return "⚫ 探测异常", str(e)


def scan_domain(domain):
    lines = [f"\n🔍 开始探测: {domain}"]

    ips, has_v6 = check_dns(domain)
    if not ips:
        lines.append("   [DNS] ❌ 无法解析 (可能被污染或屏蔽)")
        with print_lock:
            for line in lines:
                print(line)
        return

    ip_types = "IPv4 + IPv6" if has_v6 else "仅 IPv4"
    lines.append(f"   [DNS] 解析成功 ({ip_types}) -> {ips[0]}")

    http_res, http_desc = probe_url(f"http://{domain}")
    lines.append(f"   [HTTP 80]  {http_res:<8} | {http_desc}")

    https_res, https_desc = probe_url(f"https://{domain}")
    lines.append(f"[HTTPS 443] {https_res:<8} | {https_desc}")

    with print_lock:
        for line in lines:
            print(line)


def main():
    print("==================================================")
    print("               Dr.COM 白名单嗅探探针               ")
    print("==================================================")
    print("请在【未登录校园网】状态下运行，探测中请勿登录。\n")

    with ThreadPoolExecutor(max_workers=5) as executor:
        executor.map(scan_domain, TARGET_DOMAINS)

    print("\n================ 探测结束 ================")
    print("🟢 绝对畅通：可作免流跳板，HTTPS 直连目标成功")
    print("🟡 证书劫持：IP 放行但应用层被 MITM 拦截")
    print("🔴 / ⚫：完全封锁")


if __name__ == "__main__":
    main()