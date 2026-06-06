# ZYBO Z7-20 TOE (TCP/UDP Offload Engine)

ZYBO Z7-20 の PL (FPGA) に Ethernet フレーム処理を実装したオフロードエンジンです。  
現在は UDP 通信 (64 バイトペイロード) が動作し、PS (ARM Cortex-A9) から AXI4-Lite レジスタ経由でセンサデータ送受信を行えます。

---

## ハードウェア構成

| 項目 | 内容 |
|------|------|
| ボード | Digilent ZYBO Z7-20 (xc7z020clg400-1) |
| PHY | Waveshare LAN8720 ETH Board (RMII) |
| PHY 接続 | PMOD JC (TX/RX) + JD (REF_CLK) |
| ツール | Vivado 2024.2 / Vitis 2024.2 |

---

## システム概要

```
[LAN8720 PHY]
      | RMII (50 MHz)
[rmii_mac]
      |  AXI-Stream
[frame_mux] ── EtherType 0x0806 ──> [arp_engine]
      |                                   | ARP Request/Reply TX
      | EtherType 0x0800                  |
      v                             [TX Arbiter] ── [rmii_mac TX]
[udp_layer]  ←─────────────────────────┘
  ├─ TX staging buffer (64 byte)
  ├─ UDP/IP/Eth ヘッダ生成 (組み合わせ回路)
  └─ RX FIFO (xpm_fifo_sync, 512 深)
      |
[axi4lite_regs]  ← xpm_fifo_async CDC
      | AXI4-Lite
[PS7 ARM Cortex-A9]
```

---

## リポジトリ構成

```
.
├── hdl/
│   ├── rtl/
│   │   ├── mac/          # RMII MAC サブシステム (ebaz4205 移植)
│   │   └── toe/          # TOE サブシステム (新規実装)
│   └── constrs/          # XDC ピン配置・タイミング制約
├── ip_repo/
│   └── toe_top/          # Vivado カスタム IP パッケージ
├── vitis/
│   └── app_component/
│       └── src/          # ベアメタル C アプリ (UART コマンドシェル)
├── python/
│   ├── udp_server.py     # PC 側 UDP 送受信テストツール
│   ├── tcp_server.py     # PC 側 TCP サーバ (旧実装参考用)
│   └── read_regs.py      # レジスタ読み出しスクリプト
├── bitstream/
│   ├── toe_nn2.bit       # ビットストリーム (すぐに書き込んで試せる)
│   └── toe_nn2.xsa       # XSA (Vitis プラットフォーム再生成用)
├── docs/
│   ├── toe_design.md     # 設計仕様書 (モジュール階層・レジスタマップ・手順)
│   ├── history.md        # 設計履歴
│   ├── analysis.md       # 解析メモ
│   └── blog.md           # 開発ログ
└── project_1.xpr         # Vivado プロジェクトファイル
```

---

## 開発状況

> **UDP 通信を実装中。ARP・UDP TX/RX の合成・テストを継続中。**

| 機能 | 状態 | 備考 |
|------|------|------|
| FPGA クロック動作 | ✅ | 50 MHz RMII クロック正常 |
| PS → FPGA レジスタ書き込み | ✅ | AXI4-Lite 正常 |
| Ethernet リンク確立 | ✅ | LAN8720 ↔ PC 直結 |
| FPGA TX 物理送出 | ✅ | rmii_tx_en sticky (LD0) |
| FPGA RX 受信 | ✅ | CRC 正常フレーム受信 (LD1, LD2) |
| ARP 解決 | ✅ | arp_mac_valid sticky (LD3) |
| UDP TX (FPGA→PC) | 🔄 | udp_layer 実装済み・合成テスト中 |
| UDP RX (PC→FPGA) | 🔄 | xpm_fifo_sync 実装済み・テスト中 |
| TCP ESTABLISHED | ❌ | 多数バグ修正を経て未達成 → UDP に切替 |

### TCP が通らなかった経緯

複数のバグを修正したにもかかわらず TCP 接続確立に至らなかったため、UDP による実装に切り替えました。
詳細は [docs/analysis.md](docs/analysis.md) と [docs/blog.md](docs/blog.md) を参照。

**TCP 通信確立まであきらめずに開発を継続します。UDP で通信経路を確認後、TCP を再挑戦予定。**

---

## すぐに試す

1. ZYBO Z7-20 に Waveshare LAN8720 を PMOD JC/JD に接続する
2. Vivado でビルドしたビットストリームを ZYBO に書き込む
3. `bitstream/toe_nn2.xsa` から Vitis プラットフォームを作成し、`vitis/app_component/src/` をビルド・実行する
4. UART を開き、`help` コマンドで操作を確認する
5. PC 側で `python/udp_server.py` を起動して UDP 受信を確認する:

```
python python/udp_server.py
```

6. UART から `arp` → `arpwatch` で ARP 解決後、`send64 hello` で UDP パケット送信

---

## Vivado プロジェクトをビルドする場合

1. `project_1.xpr` を Vivado 2024.2 で開く
2. カスタム IP のパスを `ip_repo/toe_top/` に設定する  
   (Tools → Settings → IP → Repository)
3. Generate Bitstream を実行する

### ゼロから作り直す場合

詳細手順は [docs/toe_design.md](docs/toe_design.md) の「Vivado プロジェクト作成手順」を参照。

---

## AXI4-Lite レジスタマップ

ベースアドレス: `0x4000_0000` (PS デフォルト)

| オフセット | 名前 | R/W | 説明 |
|-----------|------|-----|------|
| 0x00 | CTRL | R/W | [0]=send_req, [2]=arp_req |
| 0x04 | STATUS | R | [0]=tx_busy, [5]=arp_mac_valid |
| 0x08 | LOCAL_MAC_HI | R/W | local_mac[47:32] |
| 0x0C | LOCAL_MAC_LO | R/W | local_mac[31:0] |
| 0x10 | REMOTE_MAC_HI | R/W | remote_mac[47:32] |
| 0x14 | REMOTE_MAC_LO | R/W | remote_mac[31:0] |
| 0x18 | LOCAL_IP | R/W | ローカル IP アドレス |
| 0x1C | REMOTE_IP | R/W | リモート IP アドレス |
| 0x20 | LOCAL_PORT | R/W | ローカル TCP ポート |
| 0x24 | REMOTE_PORT | R/W | リモート TCP ポート |
| 0x28 | TX_DATA | W | バイト書き込み → TX FIFO |
| 0x2C | RX_DATA | R | RX FIFO からバイト読み出し |
| 0x30 | RX_COUNT | R | RX FIFO 有効バイト数 [11:0] |

---

## ファームウェア使用例 (UDP)

```c
#define TOE_BASE 0x40000000UL

// IP/ポート設定
Xil_Out32(TOE_BASE + 0x18, 0xC0A80164);  // LOCAL_IP  192.168.1.100
Xil_Out32(TOE_BASE + 0x1C, 0xC0A80114);  // REMOTE_IP 192.168.1.20
Xil_Out32(TOE_BASE + 0x20, 12345);        // LOCAL_PORT
Xil_Out32(TOE_BASE + 0x24, 50000);        // REMOTE_PORT

// ARP 解決
Xil_Out32(TOE_BASE + 0x00, 0x4);          // arp_req
// ... STATUS[5] (arp_mac_valid) == 1 待ち ...

// 64バイト UDP 送信
for (int i = 0; i < 64; i++)
    Xil_Out32(TOE_BASE + 0x28, sensor_data[i]);
Xil_Out32(TOE_BASE + 0x00, 0x1);          // send_req (rising edge)

// UDP 受信
uint32_t cnt = Xil_In32(TOE_BASE + 0x30) & 0xFFF;
for (uint32_t i = 0; i < cnt; i++)
    uint8_t b = Xil_In32(TOE_BASE + 0x2C);
```

---

## 既知の制限事項

- UDP 64 バイト固定ペイロードのみ
- IPv6 非対応、IP フラグメント非対応
- 単一エンドポイント (1対1通信のみ)
- MDIO 制御未実装 (PHY はストラップ設定で auto-negotiation)
- RX FIFO 満杯時はペイロードをドロップ

---

## 参考

- RMII MAC: [ebaz4205_ethernet](https://github.com/nefarius/ebaz4205_ethernet) (Xilinx SV 実装)
- TCP/IP 参考実装: fix-tcpip-project (Altera MAX10 向け VHDL, L.Ratchanon 氏)
- Waveshare LAN8720 ETH Board
- Digilent ZYBO Z7 Reference Manual
