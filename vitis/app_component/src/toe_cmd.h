/*
 * toe_cmd.h  –  TOEインタラクティブシェル ヘッダ
 */
#ifndef TOE_CMD_H
#define TOE_CMD_H

#include "xil_types.h"

/* =====================================================================
 * レジスタマップ  (ベースアドレス + オフセット)
 * ===================================================================== */
#define TOE_BASE        0x40000000UL

#define REG_CTRL        0x00  /* [0]=connect [1]=disconnect [2]=arp_req */
#define REG_STATUS      0x04  /* [3:0]=tcp_state [4]=irq [5]=arp_valid */
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

/* =====================================================================
 * TCP ステート名
 * ===================================================================== */
#define ST_CLOSED       0
#define ST_SYN_SENT     1
#define ST_ESTABLISHED  2
#define ST_FIN_WAIT_1   3
#define ST_FIN_WAIT_2   4
#define ST_TIME_WAIT    5
#define ST_CLOSE_WAIT   6
#define ST_LAST_ACK     7

/* =====================================================================
 * API
 * ===================================================================== */
void toe_cmd_init(void);
void toe_cmd_poll(void);   /* メインループから毎回呼ぶ */

#endif /* TOE_CMD_H */
