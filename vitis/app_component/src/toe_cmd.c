/*
 * toe_cmd.c  –  UDP TOEインタラクティブシェル実装
 *
 * UARTから1行入力を受け付け、コマンドを実行する。
 * メインループから toe_cmd_poll() を毎回呼ぶだけでよい。
 *
 * コマンド一覧:
 *   help           ヘルプ表示
 *   reg            全レジスタ表示
 *   status         STATUS表示
 *   arp            ARP Requestを1回送信
 *   arpwatch [N]   N秒間ARPの状態をポーリング (デフォルト10秒)
 *   send64 [msg]   64バイトUDPパケット送信 (msgで先頭を埋める、残りは0)
 *   recv           RXバッファから受信データ読み出し
 *   reset          CTRL=0クリア
 */

#include "toe_cmd.h"
#include "xil_io.h"
#include "xil_printf.h"
#include "xuartps_hw.h"
#include "sleep.h"
#include <string.h>
#include <stdlib.h>
#include <stdio.h>

/* =====================================================================
 * レジスタアクセスマクロ
 * ===================================================================== */
#define WR(reg, val)   Xil_Out32(TOE_BASE + (reg), (u32)(val))
#define RD(reg)        Xil_In32 (TOE_BASE + (reg))

/* =====================================================================
 * 内部定数
 * ===================================================================== */
#define LINE_MAX   80     /* 入力行バッファサイズ */
#define PROMPT     "> "   /* プロンプト文字列 */

/* =====================================================================
 * 内部変数
 * ===================================================================== */
static char  s_line[LINE_MAX + 1];
static int   s_len = 0;
static u32   s_uart_base;

/* =====================================================================
 * コマンド実装
 * ===================================================================== */

/* ---- help ---- */
static void cmd_help(void)
{
    xil_printf("\r\n"
        "=== UDP TOE コマンド一覧 ===\r\n"
        "  help           このヘルプを表示\r\n"
        "  reg            全レジスタ内容を表示\r\n"
        "  status         STATUS表示 (tx_busy, arp_mac_valid)\r\n"
        "  arp            ARP Requestを1回送信\r\n"
        "  arpwatch [N]   N秒間ARPをポーリング (デフォルト10秒)\r\n"
        "  send64 [msg]   64バイトUDPパケット送信\r\n"
        "  recv           RXバッファから受信データを読み出し\r\n"
        "  reset          CTRL=0 (全制御ビットクリア)\r\n"
        "--- センサー (BME280/AHT20) ---\r\n"
        "  sensor         センサデータ読み取り・UART表示\r\n"
        "  sudp           センサデータをUDP送信\r\n"
        "  demo           センサループ: 送信→'ok'待ち→繰り返し\r\n"
        "  iicscan        I2Cバススキャン (デバイス確認)\r\n"
        "  iicdiag        AXI IIC ハードウェア診断\r\n"
        "\r\n");
}

/* ---- status表示サブルーチン ---- */
static void print_status(void)
{
    u32 st = RD(REG_STATUS);
    xil_printf("  STATUS=0x%08X  TX_BUSY=%u  ARP_VALID=%u\r\n",
               st,
               (st & STATUS_TX_BUSY)  ? 1 : 0,
               (st & STATUS_ARP_VALID) ? 1 : 0);
}

/* ---- reg ---- */
static void cmd_reg(void)
{
    u32 lmac_hi = RD(REG_LMAC_HI);
    u32 lmac_lo = RD(REG_LMAC_LO);
    u32 rmac_hi = RD(REG_RMAC_HI);
    u32 rmac_lo = RD(REG_RMAC_LO);
    u32 lip     = RD(REG_LIP);
    u32 rip     = RD(REG_RIP);
    u32 lport   = RD(REG_LPORT);
    u32 rport   = RD(REG_RPORT);
    u32 ctrl    = RD(REG_CTRL);
    u32 rxcnt   = RD(REG_RX_COUNT) & 0xFFFU;

    xil_printf("\r\n=== レジスタ ===\r\n");
    xil_printf("  CTRL    = 0x%08X  [send=%u arp=%u]\r\n",
               ctrl, ctrl & 1, (ctrl >> 2) & 1);
    print_status();
    xil_printf("  LOCAL   MAC %04X:%08X  IP %u.%u.%u.%u  PORT %u\r\n",
               lmac_hi, lmac_lo,
               (lip>>24)&0xFF, (lip>>16)&0xFF, (lip>>8)&0xFF, lip&0xFF,
               lport & 0xFFFF);
    xil_printf("  REMOTE  MAC %04X:%08X  IP %u.%u.%u.%u  PORT %u\r\n",
               rmac_hi, rmac_lo,
               (rip>>24)&0xFF, (rip>>16)&0xFF, (rip>>8)&0xFF, rip&0xFF,
               rport & 0xFFFF);
    xil_printf("  RX_COUNT= %u bytes\r\n\r\n", rxcnt);
}

/* ---- status ---- */
static void cmd_status(void)
{
    xil_printf("\r\n");
    print_status();
    xil_printf("\r\n");
}

/* ---- reset ---- */
static void cmd_reset(void)
{
    WR(REG_CTRL, 0x00);
    xil_printf("  CTRL = 0 にリセットしました\r\n");
}

/* ---- arp ---- */
static void cmd_arp(void)
{
    xil_printf("\r\n[ARP] Request送信...\r\n");
    WR(REG_CTRL, 0x00);
    usleep(100);
    WR(REG_CTRL, 0x04);   /* arp_req パルス */
    usleep(100);
    WR(REG_CTRL, 0x00);
    xil_printf("  arp_req パルス送信完了。arpwatch でポーリングしてください\r\n");
}

/* ---- arpwatch [N] ---- */
static void cmd_arpwatch(int sec)
{
    if (sec <= 0) sec = 10;
    xil_printf("\r\n[ARPWATCH] %d秒間ポーリング...\r\n", sec);

    WR(REG_CTRL, 0x00);
    usleep(100);
    WR(REG_CTRL, 0x04);
    usleep(100);
    WR(REG_CTRL, 0x00);

    for (int i = 0; i < sec * 2; i++) {
        usleep(500000);
        u32 st = RD(REG_STATUS);
        xil_printf("  %4dms  STATUS=0x%08X  ARP_VALID=%u\r\n",
                   (i + 1) * 500, st,
                   (st & STATUS_ARP_VALID) ? 1 : 0);
        if (st & STATUS_ARP_VALID) {
            xil_printf("  *** ARP解決成功! ***\r\n");
            break;
        }
    }
    xil_printf("\r\n");
}

/* ---- send64 [msg] ---- */
static void cmd_send64(const char *msg)
{
    u8 payload[UDP_PAYLOAD_BYTES];
    int msglen = msg ? (int)strlen(msg) : 0;
    if (msglen > UDP_PAYLOAD_BYTES) msglen = UDP_PAYLOAD_BYTES;

    /* ペイロード構築: msg で先頭を埋め、残りは 0 */
    for (int i = 0; i < UDP_PAYLOAD_BYTES; i++)
        payload[i] = (i < msglen) ? (u8)msg[i] : 0x00;

    xil_printf("\r\n[SEND64] %u bytes: \"%.*s\"...\r\n",
               (u32)UDP_PAYLOAD_BYTES, msglen, msg ? msg : "");

    /* TX FIFO に 64 バイト書き込み */
    for (int i = 0; i < UDP_PAYLOAD_BYTES; i++)
        WR(REG_TX_DATA, payload[i]);

    /* send_req パルス: 0→1 (rising edge で UDP TX 開始) */
    WR(REG_CTRL, 0x00);
    usleep(10);
    WR(REG_CTRL, 0x01);

    /* tx_busy が立つのを待つ (最大 1ms) */
    for (int i = 0; i < 100; i++) {
        usleep(10);
        if (RD(REG_STATUS) & STATUS_TX_BUSY) break;
    }

    /* tx_busy が落ちるのを待つ (最大 5ms = 106 bytes @ 50MHz RMII) */
    for (int i = 0; i < 500; i++) {
        usleep(10);
        if (!(RD(REG_STATUS) & STATUS_TX_BUSY)) break;
    }

    WR(REG_CTRL, 0x00);

    u32 st = RD(REG_STATUS);
    if (st & STATUS_TX_BUSY)
        xil_printf("  [警告] TX_BUSYが落ちませんでした\r\n");
    else
        xil_printf("  送信完了\r\n");
    xil_printf("\r\n");
}

/* ---- recv ---- */
static void cmd_recv(void)
{
    u32 cnt = RD(REG_RX_COUNT) & 0xFFFU;
    if (cnt == 0) {
        xil_printf("  受信データなし (RX_COUNT=0)\r\n");
        return;
    }
    xil_printf("\r\n[RECV] %u bytes:\r\n", cnt);
    for (u32 i = 0; i < cnt; i++) {
        u8 b = (u8)(RD(REG_RX_DATA) & 0xFFU);
        if ((i % 16) == 0)
            xil_printf("  %3u: ", i);
        xil_printf("%02X ", b);
        if ((i % 16) == 15 || i == cnt - 1)
            xil_printf("\r\n");
    }
    xil_printf("\r\n");
}

/* ---- sensor ---- */
static void cmd_sensor(void)
{
    int t, h, p;
    iic_sens_read(&t, &h, &p);

    /* 温度の符号処理 */
    if (t < 0) {
        int ta = -t;
        xil_printf("\r\n[SENSOR] T=-%d.%d°C  H=%d.%d%%  P=%d.%dhPa\r\n",
                   ta / 10, ta % 10, h / 10, h % 10, p / 10, p % 10);
    } else {
        xil_printf("\r\n[SENSOR] T=%d.%d°C  H=%d.%d%%  P=%d.%dhPa\r\n",
                   t / 10, t % 10, h / 10, h % 10, p / 10, p % 10);
    }
    xil_printf("\r\n");
}

/* ---- sudp (センサデータをUDP送信) ---- */
static void cmd_sensor_udp(void)
{
    int t, h, p;
    iic_sens_read(&t, &h, &p);

    /* ペイロード文字列を構築 (例: "T=25.1,H=60.5,P=1013.2\n") */
    char payload[64];
    int n;
    if (t < 0) {
        int ta = -t;
        n = snprintf(payload, sizeof(payload), "T=-%d.%d,H=%d.%d,P=%d.%d\n",
                     ta/10, ta%10, h/10, h%10, p/10, p%10);
    } else {
        n = snprintf(payload, sizeof(payload), "T=%d.%d,H=%d.%d,P=%d.%d\n",
                     t/10, t%10, h/10, h%10, p/10, p%10);
    }

    xil_printf("\r\n[SUDP] %d bytes: \"%.*s\"\r\n", n, n - 1, payload);

    /* TX FIFO に書き込み: 必ず UDP_PAYLOAD_BYTES (64) バイト */
    for (int i = 0; i < n; i++)
        WR(REG_TX_DATA, (u8)payload[i]);
    for (int i = n; i < UDP_PAYLOAD_BYTES; i++)
        WR(REG_TX_DATA, 0x00);

    /* send_req パルス */
    WR(REG_CTRL, 0x00);
    usleep(10);
    WR(REG_CTRL, 0x01);

    /* tx_busy 完了待ち (最大 6ms) */
    for (int i = 0; i < 100; i++) {
        usleep(10);
        if (RD(REG_STATUS) & STATUS_TX_BUSY) break;
    }
    for (int i = 0; i < 600; i++) {
        usleep(10);
        if (!(RD(REG_STATUS) & STATUS_TX_BUSY)) break;
    }
    WR(REG_CTRL, 0x00);

    if (RD(REG_STATUS) & STATUS_TX_BUSY)
        xil_printf("  [警告] TX_BUSYが落ちませんでした\r\n");
    else
        xil_printf("  送信完了\r\n");
    xil_printf("\r\n");
}

/* ---- iicscan ---- */
static void cmd_iicscan(void)
{
    xil_printf("\r\n");
    iic_scan();
    xil_printf("\r\n");
}

/* ---- iicdiag ---- */
static void cmd_iicdiag(void)
{
    xil_printf("\r\n");
    iic_diag();
    xil_printf("\r\n");
}

/* ---- demo (センサデータ送受信ループ) ---- */
static void cmd_demo(void)
{
    if (!(RD(REG_STATUS) & STATUS_ARP_VALID)) {
        xil_printf("[DEMO] ARP未解決。arpwatch でARP解決後に実行してください\r\n");
        return;
    }

    /* 前回残留RXデータをドレイン */
    {
        u32 stale = RD(REG_RX_COUNT) & 0xFFFU;
        if (stale > 0) {
            xil_printf("[DEMO] 残留RXデータ %u bytes をドレイン\r\n", (unsigned)stale);
            for (u32 i = 0; i < stale; i++) (void)RD(REG_RX_DATA);
        }
    }

    xil_printf("\r\n[DEMO] センサループ開始 (任意キーで停止)\r\n");
    xil_printf("       ZYBO→PC: センサデータUDP  |  PC→ZYBO: 'ok'\r\n\r\n");

    int loop_cnt = 0;
    int running  = 1;

    while (running) {
        /* 停止キーチェック */
        if (XUartPs_IsReceiveData(s_uart_base)) {
            (void)XUartPs_RecvByte(s_uart_base);
            xil_printf("[DEMO] キー入力で停止\r\n");
            break;
        }

        loop_cnt++;

        /* センサ読み取り */
        int t, h, p;
        iic_sens_read(&t, &h, &p);

        /* ペイロード文字列構築: "T=XX.X,H=XX.X,P=XXXX.X\n" */
        char payload[64];
        int n;
        if (t < 0) {
            int ta = -t;
            n = snprintf(payload, sizeof(payload),
                         "T=-%d.%d,H=%d.%d,P=%d.%d\n",
                         ta/10, ta%10, h/10, h%10, p/10, p%10);
            xil_printf("[DEMO#%3d] T=-%d.%d C  H=%d.%d%%  P=%d.%d hPa\r\n",
                       loop_cnt, ta/10, ta%10, h/10, h%10, p/10, p%10);
        } else {
            n = snprintf(payload, sizeof(payload),
                         "T=%d.%d,H=%d.%d,P=%d.%d\n",
                         t/10, t%10, h/10, h%10, p/10, p%10);
            xil_printf("[DEMO#%3d] T=%d.%d C  H=%d.%d%%  P=%d.%d hPa\r\n",
                       loop_cnt, t/10, t%10, h/10, h%10, p/10, p%10);
        }

        /* UDP 送信: TX FIFO は必ず UDP_PAYLOAD_BYTES (64) バイト書く必要がある */
        for (int i = 0; i < n; i++)
            WR(REG_TX_DATA, (u8)payload[i]);
        for (int i = n; i < UDP_PAYLOAD_BYTES; i++)
            WR(REG_TX_DATA, 0x00);  /* ゼロパディング */
        WR(REG_CTRL, 0x00);
        usleep(10);
        WR(REG_CTRL, 0x01);  /* send_req rising edge */
        /* tx_busy は ~9.4µs しか HIGH にならない (50MHz RMII で64バイト送信)
         * ポーリングで捕捉するより固定ディレイで待つ方が確実 */
        usleep(2000);         /* 2ms: 送信完了を保証する固定ウェイト */
        WR(REG_CTRL, 0x00);

        xil_printf("[DEMO#%3d] UDP送信 → 'ok'待ち (最大20秒)\r\n", loop_cnt);

        /* 'ok' 受信待ち: 1ms ポーリング × 最大 20000 回 (20秒)
         * Python が 15秒でタイムアウトして 'ok' を再送してくる場合も受け付けるため
         * Pythonの受信タイムアウト(15秒)より長く設定する */
        int got_ok = 0;
        for (int wait = 0; wait < 20000 && running; wait++) {
            /* 停止キーチェック */
            if (XUartPs_IsReceiveData(s_uart_base)) {
                (void)XUartPs_RecvByte(s_uart_base);
                xil_printf("[DEMO] キー入力で停止\r\n");
                running = 0;
                break;
            }

            /* 2秒ごとにハートビート表示 */
            if (wait > 0 && (wait % 2000) == 0)
                xil_printf("[DEMO#%3d] ok待ち %d秒...\r\n", loop_cnt, wait / 1000);

            u32 cnt = RD(REG_RX_COUNT) & 0xFFFU;
            if (cnt > 0) {
                /* RX バッファを最大 31 バイト読む */
                char rxbuf[32];
                u32 rlen = (cnt < 31U) ? cnt : 31U;
                for (u32 i = 0; i < rlen; i++)
                    rxbuf[i] = (char)(RD(REG_RX_DATA) & 0xFFU);
                rxbuf[rlen] = '\0';
                /* 残りをドレイン */
                for (u32 i = rlen; i < cnt; i++) (void)RD(REG_RX_DATA);

                xil_printf("[DEMO#%3d] 受信: \"%s\"\r\n\r\n", loop_cnt, rxbuf);

                if (strstr(rxbuf, "ok") != NULL)
                    got_ok = 1;
                break;
            }
            usleep(1000);
        }

        if (running && !got_ok) {
            /* タイムアウト: 停止せずに再送 (Pythonも'ok'再送して継続するため) */
            xil_printf("[DEMO#%3d] タイムアウト (20秒) → 再送\r\n", loop_cnt);
        }
    }

    xil_printf("[DEMO] 終了 (送信 %d 回)\r\n\r\n", loop_cnt);
}

/* =====================================================================
 * コマンドディスパッチ
 * ===================================================================== */
static void dispatch(const char *line)
{
    while (*line == ' ') line++;
    if (*line == '\0') return;

    char cmd[LINE_MAX + 1];
    const char *arg = "";
    int i = 0;
    while (*line && *line != ' ' && i < LINE_MAX)
        cmd[i++] = *line++;
    cmd[i] = '\0';
    while (*line == ' ') line++;
    arg = line;

    if      (strcmp(cmd, "help")    == 0 || strcmp(cmd, "?") == 0)
        cmd_help();
    else if (strcmp(cmd, "reg")     == 0)
        cmd_reg();
    else if (strcmp(cmd, "status")  == 0)
        cmd_status();
    else if (strcmp(cmd, "arp")     == 0)
        cmd_arp();
    else if (strcmp(cmd, "arpwatch") == 0)
        cmd_arpwatch(*arg ? atoi(arg) : 10);
    else if (strcmp(cmd, "send64")  == 0)
        cmd_send64(*arg ? arg : NULL);
    else if (strcmp(cmd, "recv")    == 0)
        cmd_recv();
    else if (strcmp(cmd, "reset")    == 0)
        cmd_reset();
    else if (strcmp(cmd, "sensor")   == 0)
        cmd_sensor();
    else if (strcmp(cmd, "sudp")     == 0)
        cmd_sensor_udp();
    else if (strcmp(cmd, "iicscan")  == 0)
        cmd_iicscan();
    else if (strcmp(cmd, "iicdiag") == 0)
        cmd_iicdiag();
    else if (strcmp(cmd, "demo")    == 0)
        cmd_demo();
    else
        xil_printf("  不明なコマンド: \"%s\"  (help で一覧)\r\n", cmd);
}

/* =====================================================================
 * 公開 API
 * ===================================================================== */

void toe_cmd_init(void)
{
    s_uart_base = STDIN_BASEADDRESS;
    s_len = 0;

    WR(REG_CTRL,    0x00);
    WR(REG_LMAC_HI, LOCAL_MAC_HI);
    WR(REG_LMAC_LO, LOCAL_MAC_LO);
    WR(REG_RMAC_HI, REMOTE_MAC_HI);
    WR(REG_RMAC_LO, REMOTE_MAC_LO);
    WR(REG_LIP,     LOCAL_IP);
    WR(REG_RIP,     REMOTE_IP);
    WR(REG_LPORT,   LOCAL_PORT);
    WR(REG_RPORT,   REMOTE_PORT);
    usleep(1000);  /* 2FF CDC 待ち */

    xil_printf("\r\n");
    xil_printf("========================================\r\n");
    xil_printf("  UDP TOE インタラクティブシェル\r\n");
    xil_printf("  base=0x%08X\r\n", (u32)TOE_BASE);
    xil_printf("========================================\r\n");
    xil_printf("  Local  MAC : %04X:%08X\r\n", LOCAL_MAC_HI, LOCAL_MAC_LO);
    xil_printf("  Local  IP  : %u.%u.%u.%u  Port: %u\r\n",
               (LOCAL_IP>>24)&0xFF, (LOCAL_IP>>16)&0xFF,
               (LOCAL_IP>>8)&0xFF,   LOCAL_IP&0xFF, LOCAL_PORT);
    xil_printf("  Remote MAC : %04X:%08X\r\n", REMOTE_MAC_HI, REMOTE_MAC_LO);
    xil_printf("  Remote IP  : %u.%u.%u.%u  Port: %u\r\n",
               (REMOTE_IP>>24)&0xFF, (REMOTE_IP>>16)&0xFF,
               (REMOTE_IP>>8)&0xFF,   REMOTE_IP&0xFF, REMOTE_PORT);
    xil_printf("  \"help\" でコマンド一覧\r\n");
    xil_printf("========================================\r\n");

    /* 起動1秒後に ARP Request を自動送信して MAC アドレスを解決する */
    xil_printf("[ARP] 1秒後に自動送信します...\r\n");
    usleep(1000000);   /* 1秒待機 (PHY Link-up 余裕) */
    WR(REG_CTRL, 0x00);
    usleep(100);
    WR(REG_CTRL, 0x04);   /* arp_req パルス */
    usleep(100);
    WR(REG_CTRL, 0x00);
    xil_printf("[ARP] Request送信完了 → 最大5秒ポーリング中...\r\n");

    int arp_resolved = 0;
    for (int i = 0; i < 10; i++) {
        usleep(500000);   /* 500ms × 10 = 5秒 */
        if (RD(REG_STATUS) & STATUS_ARP_VALID) {
            arp_resolved = 1;
            break;
        }
    }
    if (arp_resolved)
        xil_printf("[ARP] *** 解決成功! ***\r\n\r\n");
    else
        xil_printf("[ARP] 未解決 (PC未起動または接続未確認) → 手動で 'arpwatch' を実行\r\n\r\n");

    xil_printf(PROMPT);
}

void toe_cmd_poll(void)
{
    if (!XUartPs_IsReceiveData(s_uart_base)) return;

    u8 c = XUartPs_RecvByte(s_uart_base);

    if (c == '\r' || c == '\n') {
        xil_printf("\r\n");
        if (s_len > 0) {
            s_line[s_len] = '\0';
            dispatch(s_line);
            s_len = 0;
        }
        xil_printf(PROMPT);
    } else if ((c == '\b' || c == 127) && s_len > 0) {
        s_len--;
        xil_printf("\b \b");
    } else if (c >= 0x20 && c < 0x7F && s_len < LINE_MAX) {
        s_line[s_len++] = (char)c;
        XUartPs_SendByte(s_uart_base, c);
    }
}
