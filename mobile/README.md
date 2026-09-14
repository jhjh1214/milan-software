# milan_quote

A new Flutter project.

## Running against a local backend

The quote wizard, its pricing and its offline queue all work with no server
at all -- that is the point of it (CLAUDE.md hard rule 9). Sync, sign-in and
anything server-owned (rate cards, the property library, inventory) need a
real one. Start and seed it first -- see `deploy/README.md`'s "Local
development" section:

```sh
cd ../deploy
docker compose -f docker-compose.yml -f docker-compose.dev.yml up -d --build db api
```

Then point this app at it. The in-app "change server" field
(`ServerConfig.parse`) refuses anything that is not `https`, on purpose -- a
PIN and a non-expiring token cross this connection, and a fair's wifi is a
stranger's wifi. That check does not apply to the compile-time default, so
a local plain-`http` backend is a build flag, never something typed into
the running app:

```sh
# Android emulator: 10.0.2.2 is the special alias for the host machine.
flutter run --dart-define=MILAN_API_URL=http://10.0.2.2:8000

# A physical phone on the same Wi-Fi as this machine: use this machine's
# own LAN IP instead (ipconfig / ip addr), e.g.
flutter run --dart-define=MILAN_API_URL=http://192.168.1.23:8000
```

Seeded test accounts (PIN `4821` for all three, per `deploy/README.md`):

| Phone | Role | Name |
|---|---|---|
| 0123456789 | admin | Boss |
| 0123456780 | staff | Staff Sam |
| 0123456781 | parttime | Part-timer Amy |

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.
