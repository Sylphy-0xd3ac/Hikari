#!/bin/sh
# 把 Valkey 里的整个数据集导出成一个带时间戳的 RDB 文件，保留最近 N 份。
#
# 用 `valkey-cli --rdb` 而不是去拷 /var/lib/valkey/dump.rdb：前者让服务端
# 现场生成一份全量快照通过连接传回来，不依赖读数据目录的权限，也不会跟
# 服务端自己的 BGSAVE 抢同一个文件。
#
# 这是**同机**备份：能扛住 FLUSHALL、误删和文件损坏，扛不住磁盘或整机损失。
# 异地副本需要另外指定目的地，见 README 的运维一节。
set -eu

DEST="${HIKARI_BACKUP_DIR:-/var/backups/hikari}"
KEEP="${HIKARI_BACKUP_KEEP:-14}"

mkdir -p "$DEST"

stamp=$(date +%Y%m%d-%H%M%S)
tmp="$DEST/.hikari-$stamp.rdb.partial"
final="$DEST/hikari-$stamp.rdb"

# 先写临时名、成功后再改名：中途失败（服务端不可达、磁盘满）不会在目录里
# 留下一个看起来像备份、实际截断的文件，轮转也就不会把好副本挤掉。
valkey-cli --rdb "$tmp" >/dev/null
mv "$tmp" "$final"

# 轮转：按修改时间保留最近 KEEP 份。用 -1t 而不是文件名排序，避免时间戳
# 格式将来改动导致轮转顺序错乱。
ls -1t "$DEST"/hikari-*.rdb 2>/dev/null | tail -n +$((KEEP + 1)) | while read -r old; do
    rm -f "$old"
done

echo "backup ok: $final ($(wc -c <"$final") bytes)"
