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
};
