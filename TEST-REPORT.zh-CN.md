# v2.2.2 验证报告

2026-10-30。新增“服务与工具 → 4 → 卸载本工具”。仍有本工具活动节点时拒绝卸载，提示先到主菜单 4 → 3 删除；输入大写 UNINSTALL 才执行。卸载保留共享 sing-box、其他节点、原配置和历史数据；移除本工具入口及确认归属且为空的流量组件。

## 本版验证

本版在 Linux 临时目录通过 17 个卸载回归场景、127 项断言，涵盖取消、节点阻止、文件归属、符号链接、非空表、依赖解除失败、停止失败和卸载后数据保留。systemctl、nft、路径和锁边界使用模拟。

另通过 3 个 Linux 隔离场景：取消、活动节点阻止卸载、确认卸载后实际 systemd 依赖解除及原生空 nft 表移除；共享服务仍在运行，配置、内核及历史记录保留。服务进程使用 sleep 替身，未验证代理转发。

| 场景 | 结果 |
| --- | --- |
| cancel_blank_wrong_and_eof | 通过 |
| active_managed_node_refused | 通过 |
| orphan_managed_tag_refused | 通过 |
| corrupt_metadata_refused | 通过 |
| foreign_manager_refused | 通过 |
| foreign_menu_refused | 通过 |
| symlink_config_refused | 通过 |
| foreign_quota_unit_refused | 通过 |
| foreign_dropin_refused | 通过 |
| foreign_nft_owner_refused | 通过 |
| populated_owned_table_refused | 通过 |
| dependency_detach_failure_restores_dropin | 通过 |
| reload_failure_restores_dropin | 通过 |
| stop_failure_preserves_manager | 通过 |
| active_legacy_preserved_success | 通过 |
| inactive_legacy_preserved_success | 通过 |
| menu_only_fresh_install_and_route_exit | 通过 |

## 附加 Linux 隔离验证

范围：real Linux flock, systemd dependency detachment and native empty nft-table removal; private paths/unit aliases; sleeper services stand in for proxy processes

| 场景 | 结果 |
| --- | --- |
| cancel_keeps_real_units_and_files | 通过 |
| active_managed_node_blocks_uninstall_on_linux | 通过 |
| confirmed_uninstall_detaches_real_dependency_and_preserves_shared_service_and_records | 通过 |

## 安装包与源码

- 本版管理脚本 SHA256：`c9049d2747b5469e327308030206f71986d26b4dc571e802d74cd75b4eb4a0c4`。
- 安装器内嵌管理脚本与该版本逐字节一致；保留 v2.2.1 安装器的启动和临时文件清理逻辑。
- 管理脚本及安装器通过 Bash 语法检查；七个发布文件及 ZIP 内容均进行哈希/字节一致性检查。

## 历史结果

v2.2.1 在 2026-10-30 的 5 个真实 Linux 协议/额度/systemd 隔离场景及 3 个真实 flock 场景属于历史结果，未冒称是 v2.2.2 重新执行。v2.2.0 的 9 个 Windows 核心互通场景、168 个离线断言和 9 个系统边界模拟交互场景同样只作为历史基线。

## 范围与数据

本报告的当前场景数仅包含上列、与本版源码哈希一致的测试。服务或 nft 边界采用模拟时，不将其称为原生 systemd/nft 执行结果。包未部署到生产服务器，也未在生产服务器执行卸载。公网入口、云安全组及各客户端导入界面不属于此次卸载功能验证范围。

发布包只有代码、说明、来源和脱敏验证摘要；不包含服务器配置、密钥、完整节点链接或私有日志。卸载备份及累计记录保留在服务器私有目录，不上传代码仓库。
