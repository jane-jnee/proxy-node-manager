# v2.1.1 验证报告

2026-10-29。此次修复共 77 项回归检查通过：17 项旧版 nftables 归属校验兼容检查，以及原有完整 60 项流量状态、规则、异常恢复检查。另通过管理脚本与 installer 的 Bash 语法检查，管理脚本 --version 输出 2.1.1。

旧版 nftables 1.0.2 的 JSON 不含 table.comment，但原生文本保留该字段。新版仅对缺失字段采用原生输出核对：family、表名、handle、唯一表级 owner 注释和完整括号结构。显式 null 或外来 JSON 注释不允许回退，原有链、规则和数值校验继续执行。

17 项兼容检查包括正常旧版输出、现代 JSON（包括无 handle）、外来或缺失注释、链注释冒充表注释、重复注释、错误 family/表名/handle、额外表、括号不完整、原生读取失败和异常链优先级。

60 项流量回归在隔离临时目录完整运行，nft/systemd/服务启停由模拟边界替代。未在真实 Linux 内核执行规则，未登录用户 VPS，也未确认用户服务已恢复。现有 2.1.0 的其他验证作为历史结果，不能把历史项数冒充本次重新运行。

根因依据：官方 nftables 1.0.2 src/json.c 的 table_print_json 不输出 comment；src/rule.c 的 table_print 输出原生表级 comment。

官方源码：https://www.netfilter.org/projects/nftables/files/nftables-1.0.2.tar.bz2
