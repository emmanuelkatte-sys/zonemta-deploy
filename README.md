# ZoneMTA 自动部署模块 (纯净安全版)

本仓库提供 ZoneMTA (ZonePMTA) 现代高并发邮局自动化安装、配置与管理资源。
所有后门、外发及未经授权的遥测代码已彻底清除。

## 包含文件
- `configure_zonemta.sh`: ZoneMTA 单机一键配置脚本（纯净版）
- `configure.sh_zonemta.template`: 动态模板（供发信控制台批量部署使用）
- `plugins/log_delivered.js`: 纯净本地投递统计插件（无 Telegram，无收件人泄露）
- `repack_zonemta_bundle.py`: 离线 Bundle 打包工具
- `bundle_zonemta.txt`: 离线包元数据与 SHA256 校验和

## Release 离线安装包
预编译并清理完毕的离线包 `zonemta-bundle-v1.4.tar.gz` 存放在本仓库的 [Releases](../../releases) 页面中。
