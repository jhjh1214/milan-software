/**
 * English. The reference wording — the other two are translations of this.
 *
 * Kept as the file to edit first when copy changes, so ZH and MS are always
 * translating something that exists rather than each other.
 */

import type { Strings } from './strings';

export const EN: Strings = {
  common: {
    loading: 'Loading…',
    tryAgain: 'Try again',
    reload: 'Reload',
    cancel: 'Cancel',
    save: 'Save',
    saving: 'Saving…',
    notAdmin: 'Only an admin can do that.',
    signedOut: 'Signed out. Sign in again.',
    noAnswer: 'No answer from the server.',
    wentWrong: 'Something went wrong.',
    serverAnswered: (status) => `The server answered ${status}.`,
  },

  status: {
    confirmed: 'Confirmed',
    measurement_booked: 'Measurement booked',
    measured: 'Measured',
    material_selected: 'Material chosen',
    in_production: 'In production',
    ready: 'Ready to install',
    installed: 'Installed',
    closed: 'Closed',
    cancelled: 'Cancelled',
  },

  channel: {
    fair: 'Fair',
    showroom: 'Showroom',
    home_visit: 'Home visit',
    referral: 'Referral',
    phone: 'Phone',
  },

  nav: {
    orders: 'Orders',
    measurement: 'Measurement',
    priceChanges: 'Price changes',
    priceList: 'Price list',
    reports: 'Reports',
    people: 'People',
    signOut: 'Sign out',
    language: 'Language',
  },

  signIn: {
    phone: 'Phone',
    pin: 'PIN',
    action: 'Sign in',
    busy: 'Signing in…',
    wrong: 'That phone and PIN do not match.',
    throttled: 'Too many tries. Wait a moment and try again.',
    offline: 'No answer from the server.',
    server: 'Something went wrong signing in.',
  },

  board: {
    title: 'Orders',
    showing: (shown, total) => `Showing ${shown} of ${total}`,
    stage: 'Stage',
    whereFrom: 'Where from',
    all: 'All',
    nothingMatches: 'Nothing matches these filters.',
    pendingSync: 'Pending sync',
    noName: 'No name',
    taken: 'taken',
    rateHeldTo: (date) => `Rate held to ${date}`,
    stillToMeasure: (lines) => `${lines} still to measure`,
    signedOut: 'Signed out. Sign in again to see the board.',
    wentWrong: 'Something went wrong loading the board.',
  },
};
