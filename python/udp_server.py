#!/usr/bin/env python3
"""
udp_server.py  –  FPGA UDP 送受信テストツール

Usage:
  python udp_server.py [--host HOST] [--port PORT] [--send MSG]

  --host HOST   バインドするIPアドレス (デフォルト: 0.0.0.0)
  --port PORT   ポート番号 (デフォルト: 50000)
  --send MSG    FPGAへ送信する文字列 (省略時は受信専用)

FPGA設定 (toe_cmd.h):
  LOCAL_IP  = 192.168.1.100   (FPGA)
  LOCAL_PORT = 12345
  REMOTE_IP  = 192.168.1.20   (PC / このスクリプト)
  REMOTE_PORT = 50000
"""

import socket
import argparse
import threading
import time

PAYLOAD_BYTES = 64
FPGA_IP   = "192.168.1.100"
FPGA_PORT = 12345

def recv_loop(sock):
    """受信スレッド: 64バイトペイロードを16進 + ASCII で表示"""
    pkt_count = 0
    while True:
        try:
            data, addr = sock.recvfrom(1500)
        except OSError:
            break
        pkt_count += 1
        print(f"\n[RX #{pkt_count}] from {addr[0]}:{addr[1]}  ({len(data)} bytes)")
        # hex dump
        for i in range(0, len(data), 16):
            chunk = data[i:i+16]
            hex_part = " ".join(f"{b:02X}" for b in chunk)
            asc_part = "".join(chr(b) if 0x20 <= b < 0x7F else "." for b in chunk)
            print(f"  {i:3d}: {hex_part:<47}  {asc_part}")

def main():
    parser = argparse.ArgumentParser(description="FPGA UDP テストサーバ")
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=50000)
    parser.add_argument("--send", default=None,
                        help="FPGAへ送信するメッセージ (64バイトに切り詰め/0パディング)")
    args = parser.parse_args()

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind((args.host, args.port))
    print(f"[UDP] Listening on {args.host}:{args.port}")
    print(f"      FPGA = {FPGA_IP}:{FPGA_PORT}")
    print("      Ctrl+C で終了\n")

    t = threading.Thread(target=recv_loop, args=(sock,), daemon=True)
    t.start()

    if args.send:
        payload = args.send.encode()[:PAYLOAD_BYTES]
        payload = payload.ljust(PAYLOAD_BYTES, b"\x00")
        sock.sendto(payload, (FPGA_IP, FPGA_PORT))
        print(f"[TX] Sent {PAYLOAD_BYTES} bytes to {FPGA_IP}:{FPGA_PORT}: {args.send!r}")

    try:
        while True:
            line = input()
            if not line:
                continue
            payload = line.encode()[:PAYLOAD_BYTES]
            payload = payload.ljust(PAYLOAD_BYTES, b"\x00")
            sock.sendto(payload, (FPGA_IP, FPGA_PORT))
            print(f"[TX] Sent {PAYLOAD_BYTES} bytes: {line!r}")
    except (KeyboardInterrupt, EOFError):
        print("\n終了します")
    finally:
        sock.close()

if __name__ == "__main__":
    main()
