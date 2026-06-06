"""
TOE テスト用 TCP サーバー
ZYBO Z7-20 + Waveshare LAN8720 からの接続を受け付ける

使い方:
    python tcp_server.py

ZYBO (192.168.1.100:12345) から接続してくる。
接続後、文字列を送受信して切断されるまで待機する。
"""

import socket
import time

# ---- 設定 -------------------------------------------------------
LISTEN_IP   = "0.0.0.0"   # 全 IF で受け付ける
LISTEN_PORT = 50000        # main.c の REMOTE_PORT と合わせる
TIMEOUT_SEC = 30           # 受信タイムアウト
# -----------------------------------------------------------------


def run_server():
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind((LISTEN_IP, LISTEN_PORT))
    server.listen(1)
    server.settimeout(1.0)  # accept を 1 秒ごとに起こして Ctrl+C を受け取る

    print(f"[SERVER] ポート {LISTEN_PORT} で待機中...")
    print(f"[SERVER] ZYBO (192.168.1.100) からの接続を待っています")
    print(f"[SERVER] 終了: Ctrl+C\n")

    try:
        while True:
            # ---- 接続待ち (1秒タイムアウトでポーリング) ----
            try:
                conn, addr = server.accept()
            except socket.timeout:
                continue  # タイムアウト → ループ先頭に戻り Ctrl+C チェック

            print(f"[SERVER] 接続: {addr[0]}:{addr[1]}")
            conn.settimeout(TIMEOUT_SEC)

            try:
                # ---- ZYBO からのデータを受信 ----
                print("[SERVER] ZYBOからのデータ待ち...")
                rx = conn.recv(1024)
                if rx:
                    print(f"[RX] {len(rx)} bytes: {rx.decode('ascii', errors='replace').strip()!r}")
                else:
                    print("[RX] 空データ (接続終了)")

                # ---- PC からデータを送信 ----
                msg = b"Hello from PC!\r\n"
                conn.send(msg)
                print(f"[TX] {len(msg)} bytes: {msg.decode().strip()!r}")

                # ---- 追加データがあれば受信 ----
                try:
                    extra = conn.recv(1024)
                    if extra:
                        print(f"[RX] 追加 {len(extra)} bytes: {extra!r}")
                except socket.timeout:
                    pass

            except KeyboardInterrupt:
                raise  # 外側の except に伝播させて終了
            except socket.timeout:
                print("[SERVER] タイムアウト")
            except ConnectionResetError:
                print("[SERVER] 接続リセット (ZYBOが切断)")
            except Exception as e:
                print(f"[SERVER] エラー: {e}")
            finally:
                conn.close()
                print(f"[SERVER] 切断: {addr[0]}:{addr[1]}\n")
                print("[SERVER] 次の接続を待機中...\n")

    except KeyboardInterrupt:
        print("\n[SERVER] Ctrl+C 受信 → 終了")
    finally:
        server.close()


if __name__ == "__main__":
    run_server()
