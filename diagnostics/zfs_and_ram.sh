#!/bin/bash
#rivlid

echo "=== Полная диагностика ==="
echo "1. Общая RAM: $(free -h | awk '/^Mem:/ {print $2}')"
echo "2. Используется: $(free -h | awk '/^Mem:/ {print $3}')"
echo "3. Свободно: $(free -h | awk '/^Mem:/ {print $4}')"
echo "4. ARC size: $(cat /proc/spl/kstat/zfs/arcstats | awk '/^size/ {printf "%.1f", $3/1024/1024/1024}') GB"
echo "5. Hit ratio: $(awk '/^hits/ {h=$3} /^misses/ {m=$3} END {printf "%.1f%%", h/(h+m)*100}' /proc/spl/kstat/zfs/arcstats)"
echo "6. Количество ВМ: $(qm list | wc -l)"
echo "7. Память всех ВМ: $(qm list | awk 'NR>1 {sum+=$4} END {printf "%.1f", sum/1024}') GB"
