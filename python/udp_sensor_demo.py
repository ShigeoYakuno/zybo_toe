#!/usr/bin/env python3
"""
udp_sensor_demo.py  --  ZYBO センサループデモ (PC側)

動作:
  1. ZYBO から UDP でセンサデータ ("T=XX.X,H=XX.X,P=XXXX.X\n") を受信
  2. データを表示・CSV保存
  3. 1秒後に 'ok' を ZYBO へ送信
  4. 以降ループ

ZYBO 側: 'demo' コマンドを実行

Usage:
  python udp_sensor_demo.py [--save sensor_log.csv]

ZYBO/PC 設定 (toe_cmd.h と合わせること):
  ZYBO_IP   = 192.168.1.100  LOCAL_IP
  ZYBO_PORT = 12345          LOCAL_PORT  ('ok' の送信先)
  PC_PORT   = 50000          REMOTE_PORT (受信ポート)
"""

import socket
import time
import datetime
import argparse
import csv
import sys
import os

ZYBO_IP   = "192.168.1.100"
ZYBO_PORT = 12345    # ZYBO の LOCAL_PORT → 'ok' の送信先
PC_PORT   = 50000    # ZYBO の REMOTE_PORT → PC の受信ポート
OK_DELAY  = 1.0      # 'ok' を返すまでの待機時間 [秒]
RX_TIMEOUT = 5.0     # 受信タイムアウト [秒]


def parse_sensor(msg: str) -> dict | None:
    """
    "T=25.1,H=60.5,P=997.5" をパースして辞書を返す。
    パース失敗時は None。
    """
    result = {}
    try:
        for field in msg.strip().split(","):
            key, val = field.split("=")
            result[key.strip()] = float(val.strip())
        if "T" in result and "H" in result and "P" in result:
            return result
    except (ValueError, AttributeError):
        pass
    return None


def main():
    parser = argparse.ArgumentParser(description="ZYBO センサループデモ (PC側)")
    parser.add_argument("--save", default=None, metavar="FILE",
                        help="センサデータを CSV に保存 (例: sensor_log.csv)")
    parser.add_argument("--delay", type=float, default=OK_DELAY,
                        help=f"'ok' 送信までの待機秒数 (デフォルト: {OK_DELAY})")
    parser.add_argument("--zybo-ip",   default=ZYBO_IP)
    parser.add_argument("--zybo-port", type=int, default=ZYBO_PORT)
    parser.add_argument("--pc-port",   type=int, default=PC_PORT)
    args = parser.parse_args()

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("0.0.0.0", args.pc_port))
    sock.settimeout(0.5)   # 短いポーリング間隔で Ctrl+C をすぐ検知する

    csv_file = None
    csv_writer = None
    if args.save:
        write_header = not os.path.exists(args.save)
        csv_file = open(args.save, "a", newline="", encoding="utf-8")
        csv_writer = csv.writer(csv_file)
        if write_header:
            csv_writer.writerow(["timestamp", "T_degC", "H_pct", "P_hPa"])

    print("=" * 55)
    print("  ZYBO センサループデモ")
    print(f"  受信: 0.0.0.0:{args.pc_port}")
    print(f"  送信: {args.zybo_ip}:{args.zybo_port}  ('ok')")
    print(f"  待機: {args.delay:.1f}s  タイムアウト: {RX_TIMEOUT:.0f}s")
    if args.save:
        print(f"  ログ: {args.save}")
    print("  Ctrl+C で終了")
    print("=" * 55)
    print()
    print("ZYBO で 'demo' コマンドを実行してください...\n")

    loop_cnt = 0
    _next_retry = time.monotonic() + RX_TIMEOUT   # 初回リトライ期限
    try:
        while True:
            # センサデータ受信 (0.5s ポーリング → Ctrl+C 即応)
            try:
                data, addr = sock.recvfrom(1500)
                _next_retry = time.monotonic() + RX_TIMEOUT   # 受信成功でリセット
            except socket.timeout:
                # RX_TIMEOUT 秒以上データが来なければ 'ok' を再送
                if time.monotonic() >= _next_retry:
                    print(f"[TIMEOUT] {RX_TIMEOUT:.0f}秒データなし → 'ok'再送して継続")
                    sock.sendto(b"ok", (args.zybo_ip, args.zybo_port))
                    print(f"              → TX 'ok' (再送) → {args.zybo_ip}:{args.zybo_port}\n")
                    _next_retry = time.monotonic() + RX_TIMEOUT
                continue

            ts     = datetime.datetime.now()
            ts_str = ts.strftime("%H:%M:%S.%f")[:-3]
            # NULバイト (64バイトパディングの残り) を除去してからデコード
            raw    = data.replace(b"\x00", b"").decode("ascii", errors="replace")

            # 1パケットに複数行が含まれる場合も各行を個別に処理
            lines = [l.strip() for l in raw.splitlines() if l.strip()]
            if not lines:
                lines = [raw.strip()]

            any_parsed = False
            for line in lines:
                loop_cnt += 1
                parsed = parse_sensor(line)
                if parsed:
                    any_parsed = True
                    t = parsed["T"]
                    h = parsed["H"]
                    p = parsed["P"]
                    print(f"[#{loop_cnt:4d}  {ts_str}]  "
                          f"T={t:+6.1f}°C  H={h:5.1f}%  P={p:7.1f}hPa"
                          f"  (from {addr[0]}:{addr[1]})")
                    if csv_writer:
                        csv_writer.writerow([ts.isoformat(), t, h, p])
                        csv_file.flush()
                else:
                    print(f"[#{loop_cnt:4d}  {ts_str}]  RAW: {line!r}"
                          f"  (from {addr[0]}:{addr[1]})")

            # パケット1つにつき 'ok' を1回だけ返す
            time.sleep(args.delay)
            sock.sendto(b"ok", (args.zybo_ip, args.zybo_port))
            print(f"              → TX 'ok' → {args.zybo_ip}:{args.zybo_port}\n")
            _next_retry = time.monotonic() + RX_TIMEOUT   # 正常送信後もリセット

    except KeyboardInterrupt:
        print("\n[中断] Ctrl+C")
    finally:
        sock.close()
        if csv_file:
            csv_file.close()
        print(f"\n[完了] 受信 {loop_cnt} 回")
        if args.save and loop_cnt > 0:
            print(f"       ログ保存先: {args.save}")


if __name__ == "__main__":
    main()
