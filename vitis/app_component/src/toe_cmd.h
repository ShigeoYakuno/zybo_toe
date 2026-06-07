/*
 * toe_cmd.h  –  UDP TOEインタラクティブシェル ヘッダ
 */
#ifndef TOE_CMD_H
#define TOE_CMD_H

#include "xil_types.h"
#include "iic_sens.h"

/* =====================================================================
 * レジスタマップ  (ベースアドレス + オフセット)
 * ===================================================================== */
#define TOE_BASE        0x40000000UL

#define REG_CTRL        0x00  /* [0]=send_req [2]=arp_req */
#define REG_STATUS      0x04  /* [0]=tx_busy [5]=arp_mac_valid */
#define REG_LMAC_HI     0x08  /* local_mac[47:32] */
#define REG_LMAC_LO     0x0C  /* local_mac[31:0]  */
#define REG_RMAC_HI     0x10  /* remote_mac[47:32] */
#define REG_RMAC_LO     0x14  /* remote_mac[31:0]  */
#define REG_LIP         0x18  /* local_ip  */
#define REG_RIP         0x1C  /* remote_ip */
#define REG_LPORT       0x20  /* local_port  */
#define REG_RPORT       0x24  /* remote_port */
#define REG_TX_DATA     0x28  /* TXバッファへ1バイトpush */
#define REG_RX_DATA     0x2C  /* RXバッファから1バイトpop */
#define REG_RX_COUNT    0x30  /* RXバッファ残バイト数 [11:0] */

/* STATUS ビット定義 */
#define STATUS_TX_BUSY   (1U << 0)
#define STATUS_ARP_VALID (1U << 5)

/* =====================================================================
 * ネットワーク設定  (環境に合わせて変更)
 * ===================================================================== */
#define LOCAL_MAC_HI    0x0200U
#define LOCAL_MAC_LO    0x00000001UL
#define LOCAL_IP        0xC0A80164UL   /* 192.168.1.100 */
#define LOCAL_PORT      12345U

#define REMOTE_MAC_HI   0xFFFFU
#define REMOTE_MAC_LO   0xFFFFFFFFUL

//#define REMOTE_MAC_HI   0xEC5AU
//#define REMOTE_MAC_LO   0x31885D2BUL   /* EC:5A:31:88:5D:2B */
#define REMOTE_IP       0xC0A80114UL   /* 192.168.1.20  */
#define REMOTE_PORT     50000U

/* UDP ペイロードサイズ */
#define UDP_PAYLOAD_BYTES  64

/* =====================================================================
 * API
 * ===================================================================== */
void toe_cmd_init(void);
void toe_cmd_poll(void);   /* メインループから毎回呼ぶ */

#endif /* TOE_CMD_H */
