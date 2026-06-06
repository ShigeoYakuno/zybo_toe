# TOE (TCP Offload Engine) 設計書

**対象ボード**: ZYBO Z7-20 (xc7z020clg400-1)  
**PHY**: Waveshare LAN8720 ETH Board (RMII, PMOD JC+JD)  
**ツール**: Vivado 2020.2 / Vitis 2020.2  
**日付**: 2026-05-21

---

## 1. システム概要

ZYBO Z7-20 の PL (FPGA) に TCP/IP スタックを実装し、PS (ARM) からシンプルな AXI4-Lite レジスタ経由でデータ送受信を行う TCP Offload Engine。

```
[LAN8720 PHY]
      |  RMII (50 MHz)
[rmii_mac] ← ebaz4205_ethernet-main から移植
      |  AXI-Stream (byte stream, no backpressure)
[frame_mux] ─── EtherType 0x0806 → [arp_engine]
      |                                    |
      │  EtherType 0x0800                  | ARP Request/Reply TX
      ↓                                    |
[tcp_layer]                                |
  ├─ [tcp_rx_hdr_dec]                      |
  ├─ [tcp_hdr_gen]     ─────────────── [TX Arbiter] ── [rmii_mac TX]
  ├─ [tcp_state_ctrl]
  ├─ [tx_buffer]  (8 KB xpm_memory_tdpram)
  ├─ [rx_buffer]  (4 KB xpm_fifo_sync)
  └─ [lfsr_isn]
      |
[axi4lite_regs]  ← CDC bridge
      |  AXI4-Lite
[PS7 (ARM Cortex-A9)]
```

---

## 2. クロック設計

| ドメイン | ソース | 周波数 | 備考 |
|---------|-------|--------|------|
| `clk_50` | LAN8720 内蔵 OSC → REF_CLK → FPGA T11 → IBUFG → BUFG | 50 MHz | MAC, TOE engine |
| `s_axi_aclk` | PS7 FCLK0 | 50 MHz | AXI4-Lite, 非同期 |

2 ドメインは同一周波数だが非同期。クロック境界の全パスは以下で保護する：
- 1bit 制御信号: 2段 FF 同期化
- データ: `xpm_fifo_async` (TX 2KB, RX 4KB)

---

## 3. モジュール階層

```
toe_top
├── IBUFG / BUFG         (ref_clk バッファ)
├── rst_sr[3:0]          (パワーオンリセット 4段 SR)
├── mdc_cnt              (MDC = clk_50 / 50 = 1 MHz)
├── rmii_mac             (RMII MAC, USE_RMII=1)
│   ├── mii_mac_rx
│   │   ├── rmii_to_axis
│   │   ├── remove_crc
│   │   └── simple_fifo
│   └── mii_mac_tx
│       ├── axis_to_rmii
│       ├── prepend_preamble
│       ├── append_crc
│       └── simple_fifo
├── axi4lite_regs        (AXI4-Lite スレーブ + CDC)
│   ├── xpm_fifo_async   (TX FIFO: AXI→clk_50, 2KB)
│   └── xpm_fifo_async   (RX FIFO: clk_50→AXI, 4KB)
└── toe_engine
    ├── frame_mux        (EtherType デマルチプレクサ)
    ├── arp_engine       (ARP Request/Reply)
    └── tcp_layer
        ├── lfsr_isn     (ISN LFSR, poly x^32+x^30+x^26+x^25+1)
        ├── rx_buffer    (4KB xpm_fifo_sync)
        ├── tx_buffer    (8KB xpm_memory_tdpram, 循環バッファ)
        ├── tcp_rx_hdr_dec
        ├── tcp_state_ctrl
        └── tcp_hdr_gen
```

---

## 4. RTL ファイル一覧

### MAC サブシステム (`vivado/rtl/mac/`)

| ファイル | 説明 |
|---------|------|
| `rmii_mac.sv` | MAC トップ (ebaz4205 移植) |
| `mii_mac_rx.sv` | RX MAC |
| `mii_mac_tx.sv` | TX MAC |
| `rmii_to_axis.sv` | RMII → AXI-Stream |
| `axis_to_rmii.sv` | AXI-Stream → RMII |
| `prepend_preamble.sv` | プリアンブル付加 |
| `append_crc.sv` | CRC 付加 |
| `remove_crc.sv` | CRC 除去・検証 |
| `crc_mac.sv` | CRC-32 計算 |
| `axis_mux.sv` | TX 内部 MUX |
| `simple_fifo.v` | 小型 FIFO |

### TOE サブシステム (`vivado/rtl/toe/`)

| ファイル | 説明 |
|---------|------|
| `toe_top.sv` | トップレベル (クロック, リセット, MAC, regs, engine) |
| `toe_engine.sv` | TOE エンジン (frame_mux + arp_engine + tcp_layer + TX arbiter) |
| `axi4lite_regs.sv` | AXI4-Lite スレーブ + CDC |
| `frame_mux.sv` | RX EtherType デマルチプレクサ |
| `arp_engine.sv` | ARP Request/Reply エンジン |
| `tcp_layer.sv` | TCP レイヤ トップ |
| `tcp_state_ctrl.sv` | TCP ステートマシン |
| `tcp_rx_hdr_dec.sv` | RX ヘッダデコーダ |
| `tcp_hdr_gen.sv` | TX ヘッダジェネレータ |
| `tx_buffer.sv` | 8KB TX 循環バッファ |
| `rx_buffer.sv` | 4KB RX FIFO |
| `lfsr_isn.sv` | 初期シーケンス番号 LFSR |

### 制約ファイル (`vivado/constrs/`)

| ファイル | 説明 |
|---------|------|
| `toe_top.xdc` | ピン配置 + タイミング制約 |

---

## 5. PMOD ピン配置

LAN8720 は PMOD JC (上段=TX, 下段=RX) に接続。

| PMOD JC | FPGA ピン | 信号名 | LAN8720 ピン |
|---------|----------|--------|-------------|
| JC1 (上1) | V15 | RMII_TXD0 | TXD0 |
| JC2 (上2) | U15 | RMII_TXD1 | TXD1 |
| JC3 (上3) | V17 | RMII_TX_EN | TXEN |
| JC4 (上4) | V18 | MDC | MDC |
| JC7 (下1) | T15 | RMII_RXD0 | RXD0 |
| JC8 (下2) | R17 | RMII_RXD1 | RXD1 |
| JC9 (下3) | T17 | RMII_CRS_DV | CRS_DV |
| JC10 (下4) | U17 | MDIO | MDIO |
| JD3 (上3) | T11 | REF_CLK (50 MHz) | XTAL1/CLKIN |

> `ref_clk` は T11 (MRCC_P) に接続し IBUFG + BUFG を通して clk_50 を生成する。

---

## 6. AXI4-Lite レジスタマップ

ベースアドレス: PS からのマッピング依存 (例: 0x4000_0000)

| オフセット | 名前 | アクセス | 説明 |
|-----------|------|---------|------|
| 0x00 | CTRL | R/W | [0]=connect_req, [1]=disconnect_req, [2]=arp_req |
| 0x04 | STATUS | R | [3:0]=tcp_state, [4]=irq_pending, [5]=arp_mac_valid |
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

### TCP ステート値 (STATUS[3:0])

| 値 | 状態 |
|----|------|
| 0 | CLOSED |
| 1 | SYN_SENT |
| 2 | ESTABLISHED |
| 3 | FIN_WAIT_1 |
| 4 | FIN_WAIT_2 |
| 5 | TIME_WAIT |
| 6 | CLOSE_WAIT |
| 7 | LAST_ACK |

---

## 7. TCP ステートマシン

Active Open のみ対応 (クライアント動作)。

```
CLOSED ──[connect_req]──→ SYN_SENT ──[SYN+ACK受信]──→ ESTABLISHED
                                  └──[timeout/RST]──→ CLOSED

ESTABLISHED ──[FIN受信]──→ CLOSE_WAIT ──[disconnect_req]──→ LAST_ACK ──[ACK]──→ CLOSED
           └──[disconnect_req]──→ FIN_WAIT_1 ──[ACK]──→ FIN_WAIT_2
                                            └──[FIN受信]──→ TIME_WAIT ──[2MSL]──→ CLOSED
```

### タイムアウト値 (50 MHz)

| タイマ | 値 | クロック数 |
|-------|-----|----------|
| SYN タイムアウト | 3 秒 | 150,000,000 |
| 2MSL (TIME_WAIT) | 100 ms | 5,000,000 |
| 再送タイムアウト | 200 ms | 10,000,000 |
| ARP 再送間隔 | 1 秒 | 50,000,000 |

---

## 8. TX チェックサム計算 (2パス方式)

データセグメント (payload_len > 0) の場合:

1. **Pass 1 (S_CSUM_PAYLOAD)**: tx_buffer からペイロードを読み出し、TCP チェックサムのペイロード部分を累積計算。
2. **S_BUILD**: 疑似ヘッダ + TCP 固定ヘッダ + ペイロードチェックサムを合算し最終 TCP チェックサムを確定。ヘッダバッファ (hdr_buf[0:59]) に書き込む。
3. **Pass 2 (S_SEND_HDR → S_SEND_PAYLOAD)**: hdr_buf をストリーム送信後、tx_buffer から再度ペイロードを読み出してストリーム送信。

制御パケット (payload_len = 0) の場合:
- 単一パス。チェックサムは組み合わせ回路で即時計算。60 バイト未満の場合は S_SEND_PAD でゼロパディング。

---

## 9. TX バッファ (tx_buffer.sv)

- **容量**: 8 KB (xpm_memory_tdpram, DEPTH_LOG2=13)
- **ポインタ**:
  - `wr_ptr`: ARM が書き込んだ最新位置
  - `send_ptr`: 次に送信するバイト (TCP ヘッダジェネレータが読む)
  - `ack_ptr`: ACK 済みの先頭 (ここまでは上書き可能)
- **再送**: `retrans_req` を受けると `send_ptr = ack_ptr` にリセット
- **バックプレッシャ**: `wr_full` は容量の 75% で HIGH (早期通知)

---

## 10. Vivado プロジェクト作成手順

1. Vivado 2020.2 を起動 → **Create Project** → RTL Project
2. ターゲット: `xc7z020clg400-1`
3. ソースファイル追加:
   - `vivado/rtl/mac/*.sv` と `vivado/rtl/mac/simple_fifo.v`
   - `vivado/rtl/toe/*.sv`
4. 制約ファイル追加: `vivado/constrs/toe_top.xdc`
5. Top module: `toe_top`
6. **IP Catalog** → Xilinx Parameterized Macros (XPM) を有効化 (通常デフォルトで有効)
7. **Synthesis** → Implementation → Generate Bitstream

### PS7 ブロックデザイン

1. **IP Integrator** → Create Block Design
2. **Zynq7 Processing System** を追加
3. FCLK0 = 50 MHz に設定
4. AXI4-Lite Master インタフェース (M_AXI_GP0) を有効化
5. `toe_top` を RTL reference として接続:
   - `s_axi_*` ← PS AXI GP0 経由 AXI Interconnect
   - `ps_resetn` ← PS FCLKRESETN[0]
   - `irq_o` → PS IRQ[0]
6. `ref_clk` は外部ポートとして維持 (PS クロックは使用しない)

---

## 11. ファームウェア使用例 (Vitis / bare-metal C)

```c
#define TOE_BASE 0x40000000UL

// アドレス設定
Xil_Out32(TOE_BASE + 0x08, 0x0000);              // LOCAL_MAC_HI
Xil_Out32(TOE_BASE + 0x0C, 0xAABBCCDD);          // LOCAL_MAC_LO
Xil_Out32(TOE_BASE + 0x10, 0x0000);              // REMOTE_MAC_HI (ARP後更新)
Xil_Out32(TOE_BASE + 0x14, 0x11223344);          // REMOTE_MAC_LO
Xil_Out32(TOE_BASE + 0x18, 0xC0A80101);          // LOCAL_IP  192.168.1.1
Xil_Out32(TOE_BASE + 0x1C, 0xC0A80102);          // REMOTE_IP 192.168.1.2
Xil_Out32(TOE_BASE + 0x20, 5000);                // LOCAL_PORT
Xil_Out32(TOE_BASE + 0x24, 5000);                // REMOTE_PORT

// ARP 実行
Xil_Out32(TOE_BASE + 0x00, 0x4);                 // arp_req=1
// wait...
Xil_Out32(TOE_BASE + 0x00, 0x0);

// TCP 接続
Xil_Out32(TOE_BASE + 0x00, 0x1);                 // connect_req=1
// wait until STATUS[3:0] == 2 (ESTABLISHED)

// データ送信
for (int i = 0; i < len; i++)
    Xil_Out32(TOE_BASE + 0x28, buf[i]);          // TX_DATA

// データ受信
uint32_t count = Xil_In32(TOE_BASE + 0x30);      // RX_COUNT
for (int i = 0; i < count; i++)
    buf[i] = Xil_In32(TOE_BASE + 0x2C) & 0xFF;  // RX_DATA

// TCP 切断
Xil_Out32(TOE_BASE + 0x00, 0x2);                 // disconnect_req=1
```

---

## 12. 既知の制限事項

| 項目 | 詳細 |
|------|------|
| 接続数 | 単一接続のみ (Active Open) |
| MSS | ハードウェア固定なし; 相手側 MSS に従う |
| ウィンドウサイズ | 固定 4096 バイト |
| 受信フロー制御 | rx_buffer が満杯の場合、ペイロードバイトをドロップ |
| IP フラグメント | 非対応 (DF bit = 1 で送信) |
| IPv6 | 非対応 |
| RMII エラー | MAC が CRC エラーフラグ (rx_tuser) をセットし、デコーダがパケットをドロップ |
| MDIO | PHY はストラップ設定 (auto-negotiation)。MDIO 制御は未実装 |

---

## 13. リファレンス

- **VHDL 参考実装**: `fix-tcpip-project-main/` (Altera MAX10 向け, L.Ratchanon 氏)
- **RMII MAC**: `ebaz4205_ethernet-main/` (Xilinx SV 実装)
- **LAN8720 データシート**: Microchip LAN8720A/LAN8720AI
- **ZYBO Z7 リファレンスマニュアル**: Digilent ZYBO Z7 Reference Manual
