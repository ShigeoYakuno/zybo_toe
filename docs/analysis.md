# TOE デバッグ解析レポート

作成日: 2026-05-31  
対象: ZYBO Z7-20 + Waveshare LAN8720 ETH Board  
目標: TCP Offload Engine (TOE) による TCP 通信確立

---

## 1. 構成

```
PC (192.168.1.20, イーサネット3)
  ↕ Ethernet ケーブル (直結)
LAN8720 (RMII, Waveshare ETH Board)
  ↕ PMOD JC + JB2_N
ZYBO Z7-20 (xc7z020clg400-1)
  ├─ FPGA部: TOE IPコア (ip_repo/toe_top/)
  │    ├─ clk_50: LAN8720 NINT/REFCLKO → T12 (50MHz)
  │    └─ s_axi_aclk: PS FCLK0 (50MHz, 独立ドメイン)
  └─ PS部: ARM Cortex-A9
       └─ Vitisファームウェア (vitis/app_component/src/main.c)
```

**ピン配置 (XDC):**

| PMOD ピン | FPGA ピン | LAN8720 信号 |
|-----------|-----------|-------------|
| JC1_P V15 | V15 | TXD0 |
| JC1_N W15 | W15 | RXD1 |
| JC2_P T11 | T11 | CRS_DV |
| JC2_N T10 | T10 | MDC |
| JC3_P W14 | W14 | TX_EN |
| JC3_N Y14 | Y14 | RXD0 |
| JC4_P T12 | T12 | NINT/REFCLKO (50MHz入力) |
| JC4_N U12 | U12 | MDIO |
| JB2_N W20 | W20 | TXD1 |

⚠️ **T12は非CCIO (Clock-Capable IO)。** `CLOCK_DEDICATED_ROUTE FALSE` で強制ルーティング。

---

## 2. ファームウェア概要 (main.c)

```c
TOE_BASE = 0x40000000  // AXIスレーブベースアドレス (Vivadoで確認済み)

LOCAL_MAC  = 02:00:00:00:00:01
LOCAL_IP   = 192.168.1.100
LOCAL_PORT = 12345
REMOTE_MAC = EC:5A:31:88:5D:2B  // PCのMACアドレス
REMOTE_IP  = 192.168.1.20
REMOTE_PORT = 50000
```

実行フロー:
1. レジスタ設定 (LOCAL/REMOTE MAC/IP/PORT)
2. ARP テスト: CTRL[2]=1 でARP Request送信 → ARP Reply待機 (最大3秒)
3. TCP接続: CTRL[0]=1 でSYN送信 → ESTABLISHED待機 (最大5秒)
4. データ送信/受信
5. 切断

---

## 3. LEDデバッグ定義 (rev3以降)

| LED | 信号 | 条件 | 診断目的 |
|-----|------|------|---------|
| LD0 | tx_en_sticky | rmii_tx_en が一度でもHigh | TX送信パス確認 |
| LD1 | crs_dv_sticky | rmii_crs_dv が一度でもHigh | PHYリンク+RX確認 |
| LD2 | mac_rx_sticky | MAC RX有効バイト受信 | CRC正常受信確認 |
| LD3 | arp_mac_sticky | arp_mac_valid が一度でもHigh | ARP解決確認 |

全てstickyラッチ (リセットまで保持)。

---

## 4. 問題発生から解決までの経緯

### 4.1 初期症状

- LED0=ON, LED3=ON, LED1=OFF, LED2=OFF (旧LED定義)
- 旧LED1=arp_mac_valid → OFF → ARP解決失敗
- 旧LED2=TCP ESTABLISHED → OFF
- WiresharkにFPGAからのフレームが全く見えない

### 4.2 発見したバグ1: frame_mux の rx_idx デシンク (主要バグ)

**ファイル:** `ip_repo/toe_top/frame_mux.sv`

**問題:**
```systemverilog
// 修正前
arp_tvalid = rx_tvalid && (route == ROUTE_ARP || b_cnt <= 8'd13);
```

WindowsのPCはリンクアップ後すぐにIPv6 NDやmDNS等を自動送信する。  
これらはEtherType=0x86DD等でframe_muxでは `ROUTE_NONE` に分類される。  
`arp_tvalid` はバイト0-13のみHigh → arp_engine は rx_idx=13 で止まる。  
その後のARPフレームはrx_idx=13からカウントが始まり、**全フィールドが13バイトずれる**。  
結果: rx_oper/rx_spa等が正しく取り込めずARPリプライを認識できない。

**修正:**
```systemverilog
// 修正後
arp_tvalid = rx_tvalid && (route == ROUTE_ARP || b_cnt <= 8'd13 || rx_tlast);
```

フレーム末尾(rx_tlast)を常時転送 → arp_engine が rx_tlast でrx_idx=0にリセット。

### 4.3 発見したバグ2: TX アービタの tready ゲーティング不備

**ファイル:** `ip_repo/toe_top/toe_engine.sv`

**問題:**
```systemverilog
// 修正前: ARP/TCP両方に同じtreadyを渡していた
.tx_tready (mac_tx_tready),  // ARP
.tx_tready (mac_tx_tready),  // TCP ← ARP送信中もTCPポインタが進む
```

**修正:**
```systemverilog
// 修正後: アクティブな側にのみtreadyを渡す
.tx_tready (arp_tx_tvalid ? mac_tx_tready : 1'b0),  // ARP
.tx_tready (arp_tx_tvalid ? 1'b0 : mac_tx_tready),  // TCP
```

---

## 5. 現在の状態 (2026-05-31 更新)

### LED状態 (rev3ビットストリーム)

| LED | 状態 | 解釈 |
|-----|------|------|
| LD0 (TX) | **ON** | FPGAが送信している ✓ |
| LD1 (CRS_DV) | **ON** | LAN8720がPCフレームを受信 = **リンク確立** ✓ |
| LD2 (MAC RX) | **ON** | CRC正常フレームを受信 = RX経路正常 ✓ |
| LD3 (ARP) | **OFF** | ARPリプライ未解決 ✗ |

### Wireshark確認結果

```
Frame 79:  ARP Announcement for 192.168.1.20 (PC が自IPをアナウンス)
Frame 362: Who has 192.168.1.100? Tell 192.168.1.20 (PCがFPGAのMACを問い合わせ)
Frame 364: Who has 192.168.1.100? Tell 192.168.1.20 (再送)
Frame 367: Who has 192.168.1.100? Tell 192.168.1.20 (再送)
```

→ PCはFPGAのIPを知っているが、FPGAからの応答が来ない  
→ FPGAのARP Request (02:00:00:00:00:01発) はWiresharkに現れない

### 確認できたこと / 残課題

| 項目 | 状態 |
|------|------|
| FPGAクロック動作 | ✅ |
| PS→FPGAレジスタ書き込み | ✅ |
| Ethernetリンク確立 | ✅ |
| FPGA TX送信動作 | ✅ (LED0) |
| FPGA RX受信動作 | ✅ (LED1,2) |
| PCがFPGAのARP Requestを受信 | ❌ Wiresharkに出ない |
| FPGAがPCのARP Requestに応答 | ❌ Replyが来ない |

---

## 6. 発見したバグ3: `is_reply_pkt` ラッチなし (arp_engine.sv)

**ファイル:** `ip_repo/toe_top/arp_engine.sv`

**問題:**  
PCから "Who has 192.168.1.100?" を受信した際、FPGAはARP Replyを送ろうとするが、
`tx_send_start` 発火と同じクロックで `do_reply=0` にクリアされるため、
`is_reply_pkt = do_reply = 0` に即変わりバイト1以降がRequest内容になる。

結果として送信される"Reply"の実際の内容:
- バイト0: `0xEC` (PCのMAC先頭1バイト) ← 正しい
- バイト1-5: `FF:FF:FF:FF:FF` (ブロードキャスト) ← Request内容に化ける
- OPER byte: `0x01` (Request) ← `0x02` (Reply) であるべき

PCのNICは宛先MAC=EC:FF:FF:FF:FF:FFのフレームを受け取るが、
自分のMAC (EC:5A:31:88:5D:2B) でも ブロードキャストでもないため **NICがハードウェアで破棄**。

**修正 (2026-05-31):**
```systemverilog
// 送信中(tx_active=1)はラッチ値を使用、送信開始サイクル(tx_active=0)はdo_replyを直接使用
logic is_reply_lat = 1'b0;
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) is_reply_lat <= 1'b0;
    else if (tx_send_start) is_reply_lat <= do_reply; // 送信開始時に確定
end
logic is_reply_pkt;
assign is_reply_pkt = tx_active ? is_reply_lat : do_reply;
```

---

## 7. 未解決課題: FPGAのARP RequestがWiresharkに出ない

FPGAがARP Request (宛先=ブロードキャスト) を送信しているはずだが、
PCのWiresharkに一切表示されない。

**考えられる原因:**
- FPGA TX フレームのFCS (CRC) が間違っており、PCのNICがハードウェア破棄
- LAN8720のTX方向の動作不良
- RMII TXタイミング違反 (T12が非CCIOピン、CLOCK_DEDICATED_ROUTE FALSE)

**次のステップ:**  
バグ3修正後にビルドして再テスト。FPGAが正しいARP Replyを送れるようになれば、
PCのARP Requestへの応答は成立する可能性がある (この場合はFPGA主導のARP Requestは不要)。

---

---

## 10. 現在の状態 (2026-06-02 更新)

### LED状態 (rev7ビットストリーム)

rev7 LEDマッピング:
| LED | 信号 | 意味 |
|-----|------|------|
| LD0 | rmii_tx_en sticky | TX物理送出 |
| LD1 | arp_mac_valid sticky | ARP解決済み |
| LD2 | tcp_state==1 sticky | SYN_SENT到達 |
| LD3 | mac_tx_tvalid sticky | tcp_hdr_gen→MAC到達 |

確認されたLED状態: **LD0, LD1, LD2, LD3 全て ON**

### 診断ステップ確認結果

```
> arpwatch 5   → ARP解決成功 (LD1=ON)
> tcp          → SYN_SENT 遷移 (LD2=ON), mac_tx_tvalid (LD3=ON), rmii_tx_en (LD0=ON)
Wireshark: tcp and ip.addr == 192.168.1.100 → 何も表示されない
```

### RTLコードレビュー結果 (2026-06-02)

以下のモジュールを詳細レビュー済み:

| モジュール | チェック内容 | 結果 |
|-----------|------------|------|
| tcp_hdr_gen.sv | ヘッダバイト列 (Eth+IP+TCP) | ✓ 正しい |
| tcp_hdr_gen.sv | IPチェックサム計算 | ✓ 正しい |
| tcp_hdr_gen.sv | TCPチェックサム計算 | ✓ 正しい |
| tcp_hdr_gen.sv | TCP flags マッピング l_flags[5:0] | ✓ 正しい |
| tcp_hdr_gen.sv | 60バイトパディング (S_SEND_PAD) | ✓ 正しい (60バイト, tlast正常) |
| tcp_state_ctrl.sv | SYNパケット生成 (conn_rise時) | ✓ 正しい |
| toe_engine.sv | TXアービタ (ARP優先, treadyゲーティング) | ✓ 正しい |
| axi4lite_regs.sv | レジスタ → clk_50 2FF CDC | ✓ 正しい |

**IPチェックサム検算 (src=192.168.1.100, dst=192.168.1.20, SYN):**
```
Sum = 4500+0028+0000+4000+4006+C0A8+0164+C0A8+0114 = 0x248F6
fold = 0x0002 + 0x48F6 = 0x48F8
IP checksum = ~0x48F8 = 0xB707
```

### Wiresharkで見えない原因の仮説

| 仮説 | 可能性 | 根拠 |
|------|--------|------|
| Wireshark が誤ったNICでキャプチャ中 | **最高** | PC に複数IF (WiFi + イーサネット3) |
| SYNタイムアウト後 (3秒) にWiresharkを確認した | 高 | SYN_SENTは3秒でCLOSEDへ |
| SYN フレームのCRC/FCS エラー | 低 | ARP は同一TXパスで正常動作 |
| IPアドレスフィールド値の誤り | 低 | RTLコードで 192.168.1.100 確認済み |

### 次の診断手順

**Step 1: FPGAからの全フレームを確認**
```
Wireshark フィルタ: ether src 02:00:00:00:00:01
```
FPGAのMAC (02:00:00:00:00:01) から来る全フレームを表示。  
ARPもTCPも捕捉できる。

- **何も出ない** → キャプチャIF間違い → イーサネット3 を選択
- **ARPは出るがTCPが出ない** → TCP TX経路固有の問題
- **TCPが出る** → フィルタ条件の問題 (IPアドレス確認)

**Step 2: レジスタ値確認**
```
> reg
```
tcp実行前にLOCAL/REMOTE MAC・IP・PORT が正しい値か確認。

**Step 3: python tcp_server.py を事前に起動**
```
python tcp_server.py
```
サーバが起動していない場合、PCからRSTが返りSYNが即座にCLOSEDになる場合がある。

---

## 7. RTL修正履歴

| 日付 | ファイル | 変更内容 |
|------|---------|---------|
| 2026-05-31 | frame_mux.sv rev1 | rx_tlast常時転送でrx_idxデシンク防止 |
| 2026-05-31 | toe_engine.sv rev1 | TXアービタtreadyゲーティング修正 |
| 2026-05-31 | toe_top.sv rev3 | LEDデバッグ再設計 (全sticky化) |
| 2026-06-01 | tcp_hdr_gen.sv rev1 | S_IDLEで即build_hdrすると<=代入未反映でDstMAC全0バグ修正 (S_BUILDを経由) |
| 2026-06-01 | tcp_state_ctrl.sv rev1 | tx_busy自己クリアデッドコード削除 (tx_req_pendingが常に0) |
| 2026-06-01 | tcp_layer.sv | assign tx_busy=gen_busy の多重ドライバ削除 |
| 2026-06-01 | toe_top.sv rev5-6 | LED診断再設計 (rmii_tx_en/arp_valid/SYN_SENT/mac_tx_tvalid) |
| 2026-06-02 | toe_top.sv rev7 | LD3をTCP_ESTABLISHED→mac_tx_tvalid stickyに変更 |
| 2026-06-03 | tcp_hdr_gen.sv rev2 | build_hdr()タスク内hdr_buf代入を`=`→`<=`に変更: always_ff内ブロッキング代入でVivadoがFF更新を正しく合成しない問題を修正（hdr_bufが全0→dst MAC=00:00:00:00:00:00→NICに破棄） |

---

## 8. AXI4-Lite レジスタマップ (参考)

ベースアドレス: `0x40000000`

| オフセット | 名前 | 方向 | ビット定義 |
|-----------|------|------|-----------|
| 0x00 | CTRL | W/R | [0]=connect_req [1]=disconnect_req [2]=arp_req |
| 0x04 | STATUS | R | [3:0]=tcp_state [4]=irq [5]=arp_mac_valid |
| 0x08 | LOCAL_MAC_HI | W/R | [15:0]=local_mac[47:32] |
| 0x0C | LOCAL_MAC_LO | W/R | [31:0]=local_mac[31:0] |
| 0x10 | REMOTE_MAC_HI | W/R | [15:0]=remote_mac[47:32] |
| 0x14 | REMOTE_MAC_LO | W/R | [31:0]=remote_mac[31:0] |
| 0x18 | LOCAL_IP | W/R | [31:0] |
| 0x1C | REMOTE_IP | W/R | [31:0] |
| 0x20 | LOCAL_PORT | W/R | [15:0] |
| 0x24 | REMOTE_PORT | W/R | [15:0] |
| 0x28 | TX_DATA | W | [7:0]=TXバッファへpush |
| 0x2C | RX_DATA | R | [7:0]=RXバッファからpop |
| 0x30 | RX_COUNT | R | [11:0]=受信バイト数 |

---

---

## 11. UDP 双方向通信 動作確認 (2026-06-06)

### 動作確認済み内容

| 方向 | コマンド/ツール | 結果 |
|------|--------------|------|
| FPGA → PC | `send64 <文字列>` | PC 側 udp_server.py で受信確認 |
| PC → FPGA | udp_server.py から送信 | `recv` コマンドで正しい文字列表示 |

### 修正したバグ (UDP パス)

#### Bug-U1: udp_layer.sv — rx_tuser ゲーティング

`mii_mac_rx` の tuser 信号の仕様を誤解していた。  
`tuser=1` は「CRC エラー」ではなく「CRC 未確定」を意味し、tlast 以外の全バイトで 1 が出力される。  
`rx_fifo_wr_en` に `!rx_tuser` を含めていたため、ペイロードバイトが一切 FIFO に書き込まれなかった。

→ `!rx_tuser` 条件を削除。

#### Bug-U2: axi4lite_regs.sv — xpm_fifo_async rd_data_count

`USE_ADV_FEATURES("0004")` は bit2 (wr_data_count) のみ有効化。  
rd_data_count (bit10) が無効のため `rx_afifo_rd_count` = 0 → `RX_COUNT` レジスタが常に 0 を返した。  
加えて `RD_DATA_COUNT_WIDTH` 未指定でデフォルト 1 bit → 64 バイトのカウントが切り捨てられていた。

→ `USE_ADV_FEATURES("0400")` + `RD_DATA_COUNT_WIDTH(13)` に修正。

#### Bug-U3: toe_top.xdc — IOB TRUE 配置エラー

Vivado 2024.2 `[Place 30-722]`: T12 は非 CCIO ピンのためクロックが IOB FF に届かず配置不可能。

→ `set_property IOB TRUE` 行を削除。

---

## 12. TCP モジュール レビュー結果 (2026-06-06)

UDP 動作確認後、TCP モジュール群に同様のバグがないかレビューを実施した。

### mii_mac_rx tuser 仕様の整理

| バイト種別 | tuser の値 |
|-----------|-----------|
| tlast 以外 (ペイロード/ヘッダ中) | **1** (CRC 未確定、判断不可) |
| tlast (フレーム末尾) | 0=CRC 正常 / 1=CRC エラー |

**tuser は tlast バイトでのみ意味を持つ。** ペイロード書き込みロジックで `!rx_tuser` を
条件にするとペイロード全バイトがブロックされる。

### 各モジュールの確認結果

| モジュール | tuser バグ | FIFO 設定 | その他 | 対処 |
|-----------|-----------|---------|------|------|
| tcp_rx_hdr_dec.sv | rev1 で修正済み | N/A (FIFO なし) | NBA バグ rev2 修正済み | 対応不要 |
| rx_buffer.sv | N/A | **READ_MODE="std" → FWFT 必須** | — | **今回修正** |
| tx_buffer.sv | N/A | xpm_memory_tdpram 使用 | — | 対応不要 |
| tcp_hdr_gen.sv | N/A | N/A | rev1〜3 修正済み | 対応不要 |
| tcp_state_ctrl.sv | N/A | N/A | tx_busy クリア未実装 (ARM 非公開) | 影響なし |
| lfsr_isn.sv | N/A | N/A | 問題なし | 対応不要 |

### rx_buffer.sv の FWFT バグ詳細

axi4lite_regs の RX ドレイン回路はコンビネーショナル接続を前提とした設計:

```
empty=0 → rx_rd_en=1 → rx_afifo_wr_en=1, rx_afifo_din=rx_rd_data (現サイクルで有効)
```

std モード (latency=1) では `rd_en` アサートの 1 クロック後にデータが確定するため、
`rx_afifo_din` には前のサイクルの dout (初回は不定/0) が書き込まれ、全バイトが化ける。

FWFT モード (latency=0) では `empty=0` の時点で dout に有効データが出ているため正常動作する。  
UDP の `udp_layer.sv` の rx_fifo が `READ_MODE("fwft"), FIFO_READ_LATENCY(0)` であることからも、
同じドレイン回路を共用する rx_buffer は FWFT であるべきだったと分かる。

---

## 9. TCP ステート定義

| 値 | 名前 | 意味 |
|----|------|------|
| 0 | CLOSED | 切断状態 |
| 1 | SYN_SENT | SYN送信済み、応答待ち |
| 2 | ESTABLISHED | 接続確立 |
| 3 | FIN_WAIT_1 | FIN送信済み |
| 4 | FIN_WAIT_2 | FIN/ACK受信済み |
| 5 | TIME_WAIT | 2MSL待機中 |
| 6 | CLOSE_WAIT | 相手からFIN受信 |
| 7 | LAST_ACK | FIN送信後ACK待ち |
