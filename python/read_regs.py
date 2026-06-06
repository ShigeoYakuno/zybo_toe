"""
TOE レジスタ確認ツール (デバッグ用)
xsct (Xilinx System Console) 経由でレジスタを読む場合のリファレンス。

このスクリプト自体は PC 上で直接実行するものではなく、
Vitis の Tcl Console / xsct で使うコマンドの参考として使う。

--- Vitis Tcl Console でのレジスタ読み方 ---

connect
targets -set -filter {name =~ "ARM*#0"}

# レジスタ読み出し (ベースアドレス 0x40000000)
mrd 0x40000000       ;# CTRL
mrd 0x40000004       ;# STATUS (TCP state + IRQ)
mrd 0x40000018       ;# LOCAL_IP
mrd 0x4000001C       ;# REMOTE_IP
mrd 0x40000030       ;# RX_COUNT

# connect_req を立てる (CTRL bit0)
mwr 0x40000000 0x00
after 10
mwr 0x40000000 0x01

# disconnect_req を立てる (CTRL bit1)
mwr 0x40000000 0x00
after 10
mwr 0x40000000 0x02

--- TCP state の意味 ---
STATUS[3:0]:
  0 = CLOSED
  1 = SYN_SENT
  2 = ESTABLISHED
  3 = FIN_WAIT_1
  4 = FIN_WAIT_2
  5 = TIME_WAIT
  6 = CLOSE_WAIT
  7 = LAST_ACK

STATUS[4] = IRQ (state change, read でクリア)
STATUS[5] = ARP_MAC_VALID
"""

# このファイルはリファレンス用。実行する場合は tcp_server.py を使う。
print(__doc__)
