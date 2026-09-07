/**
 * Bahasa Melayu.
 *
 * The order lifecycle words are taken verbatim from
 * `mobile/lib/l10n/app_ms.arb`, for the same reason ZH takes its: the office
 * and the measurer are talking about one job, and two different words for
 * `material_selected` makes that a conversation about the software.
 */

import type { Strings } from './strings';

export const MS: Strings = {
  common: {
    loading: 'Sedang dimuatkan…',
    tryAgain: 'Cuba lagi',
    reload: 'Muat semula',
    cancel: 'Batal',
    save: 'Simpan',
    saving: 'Sedang menyimpan…',
    notAdmin: 'Hanya admin boleh buat ini.',
    signedOut: 'Sudah log keluar. Sila log masuk semula.',
    noAnswer: 'Tiada jawapan dari pelayan.',
    wentWrong: 'Ada sesuatu yang tidak kena.',
    serverAnswered: (status) => `Pelayan menjawab ${status}.`,
  },

  status: {
    confirmed: 'Disahkan',
    measurement_booked: 'Ukuran ditempah',
    measured: 'Sudah diukur',
    material_selected: 'Bahan dipilih',
    in_production: 'Sedang dibuat',
    ready: 'Sedia dipasang',
    installed: 'Sudah dipasang',
    closed: 'Selesai',
    cancelled: 'Dibatalkan',
  },

  channel: {
    fair: 'Pesta jualan',
    showroom: 'Bilik pameran',
    home_visit: 'Lawatan rumah',
    referral: 'Rujukan',
    phone: 'Telefon',
  },

  nav: {
    orders: 'Pesanan',
    measurement: 'Ukuran',
    priceChanges: 'Harga yang diubah',
    priceList: 'Senarai harga',
    reports: 'Laporan',
    people: 'Pengguna',
    signOut: 'Log keluar',
    language: 'Bahasa',
  },

  signIn: {
    phone: 'Nombor telefon',
    pin: 'PIN',
    action: 'Log masuk',
    busy: 'Sedang log masuk…',
    wrong: 'Nombor atau PIN salah.',
    throttled: 'Terlalu banyak cubaan. Tunggu sekejap dan cuba lagi.',
    offline: 'Tiada jawapan dari pelayan.',
    server: 'Ada masalah semasa log masuk.',
  },

  board: {
    title: 'Pesanan',
    showing: (shown, total) => `Menunjukkan ${shown} daripada ${total}`,
    stage: 'Peringkat',
    whereFrom: 'Dari mana',
    all: 'Semua',
    nothingMatches: 'Tiada pesanan yang sepadan dengan tapisan ini.',
    pendingSync: 'Menunggu penyegerakan',
    noName: 'Tiada nama',
    taken: 'diterima',
    rateHeldTo: (date) => `Harga dikunci hingga ${date}`,
    stillToMeasure: (lines) => `${lines} lagi belum diukur`,
    signedOut: 'Sudah log keluar. Log masuk semula untuk melihat pesanan.',
    wentWrong: 'Ada masalah semasa memuatkan pesanan.',
  },

  queue: {
    title: 'Senarai ukuran',
    show: 'Tunjuk',
    all: 'Semua',
    unbooked: 'Belum dihubungi',
    booked: 'Lawatan ditempah',
    jobsAcrossTrips: (jobs, trips) =>
      `${jobs} pesanan dalam ${trips} perjalanan`,
    stillToMeasure: (lines) => `${lines} lagi belum diukur`,
    nothingWaiting: 'Tiada pesanan menunggu lawatan.',
    noTripsMatch: 'Tiada perjalanan yang sepadan dengan tapisan ini.',
    noName: 'Tiada nama direkodkan',
    waiting: (days) => `Menunggu ${days} hari`,
    someBooked: (booked, jobs) => `${booked} daripada ${jobs} ditempah`,
    oneVisitCovers: (orders) =>
      `${orders} pesanan untuk satu pelanggan — satu lawatan mencukupi`,
    noPhone:
      'Tiada nombor telefon, jadi ini tidak dapat dikumpulkan dengan yang lain.',
    pendingSync: 'menunggu penyegerakan',
    toMeasure: (unmeasured, lines) =>
      `${unmeasured} daripada ${lines} perlu diukur`,
    materialsToChoose: (materials) => `${materials} bahan perlu dipilih`,
    bookedOn: (date) => `Ditempah ${date}`,
    notBooked: 'Belum ditempah',
    tripTotal: (total, oldest) =>
      `Jumlah perjalanan ${total} · deposit terawal ${oldest}`,
    signedOut: 'Sudah log keluar. Log masuk semula untuk melihat senarai.',
    wentWrong: 'Ada masalah semasa memuatkan senarai.',
  },
};
