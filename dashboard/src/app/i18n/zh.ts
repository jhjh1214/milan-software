/**
 * 中文. The default, per CLAUDE.md's conventions.
 *
 * The order lifecycle words are taken verbatim from `mobile/lib/l10n/app_zh.arb`.
 * The office and the measurer telephone each other about the same job, and two
 * different Chinese words for `material_selected` would make that conversation
 * about the software rather than about the order.
 */

import type { Strings } from './strings';

export const ZH: Strings = {
  common: {
    loading: '载入中…',
    tryAgain: '再试一次',
    reload: '重新载入',
    cancel: '取消',
    save: '保存',
    saving: '保存中…',
    notAdmin: '只有管理员可以这样做。',
    signedOut: '已登出，请重新登入。',
    noAnswer: '服务器没有回应。',
    wentWrong: '出了点问题。',
    serverAnswered: (status) => `服务器回应 ${status}。`,
  },

  status: {
    confirmed: '已确认',
    measurement_booked: '已约量尺',
    measured: '已量尺',
    material_selected: '已选料',
    in_production: '生产中',
    ready: '待安装',
    installed: '已安装',
    closed: '已结案',
    cancelled: '已取消',
  },

  channel: {
    fair: '展会',
    showroom: '门市',
    home_visit: '上门',
    referral: '介绍',
    phone: '电话',
  },

  nav: {
    orders: '订单',
    measurement: '量尺',
    priceChanges: '改价记录',
    priceList: '价格表',
    reports: '报表',
    people: '人员',
    signOut: '登出',
    language: '语言',
  },

  signIn: {
    phone: '手机号码',
    pin: '密码 PIN',
    action: '登入',
    busy: '登入中…',
    wrong: '号码或密码不对。',
    throttled: '试太多次了。等一下再试。',
    offline: '服务器没有回应。',
    server: '登入时出了点问题。',
  },

  board: {
    title: '订单',
    showing: (shown, total) => `显示 ${shown} 张，共 ${total} 张`,
    stage: '进度',
    whereFrom: '来源',
    all: '全部',
    nothingMatches: '没有订单符合这些条件。',
    pendingSync: '订单号等同步',
    noName: '没写名字',
    taken: '已收',
    rateHeldTo: (date) => `价格锁到 ${date}`,
    stillToMeasure: (lines) => `还有 ${lines} 项要量`,
    signedOut: '已登出。重新登入才能看订单。',
    wentWrong: '载入订单时出了点问题。',
  },

  queue: {
    title: '量尺排程',
    show: '显示',
    all: '全部',
    unbooked: '还没联络',
    booked: '已约时间',
    jobsAcrossTrips: (jobs, trips) => `${trips} 趟，共 ${jobs} 张单`,
    stillToMeasure: (lines) => `还有 ${lines} 项要量`,
    nothingWaiting: '没有订单在等量尺。',
    noTripsMatch: '没有行程符合这个条件。',
    noName: '没有记录名字',
    waiting: (days) => `已等 ${days} 天`,
    someBooked: (booked, jobs) => `${jobs} 张已约 ${booked} 张`,
    oneVisitCovers: (orders) => `同一位客户 ${orders} 张单 — 去一趟就够`,
    noPhone: '没有电话号码，所以没办法和其他订单归在一起。',
    pendingSync: '等同步',
    toMeasure: (unmeasured, lines) => `${lines} 项里有 ${unmeasured} 项要量`,
    materialsToChoose: (materials) => `${materials} 项要选料`,
    bookedOn: (date) => `已约 ${date}`,
    notBooked: '还没约',
    tripTotal: (total, oldest) => `这趟合计 ${total} · 最早的订金 ${oldest}`,
    signedOut: '已登出。重新登入才能看排程。',
    wentWrong: '载入排程时出了点问题。',
  },
};
