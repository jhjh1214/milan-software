# Dashboard

This project was generated using [Angular CLI](https://github.com/angular/angular-cli) version 21.2.12.

## Development server

`ng serve` alone shows every screen as "No answer from the server" -- the
dashboard calls `/api` on its own origin because in production Caddy serves
both the app and the API from one host, and `ng serve` has nothing behind
it. `proxy.conf.json` (already wired into `angular.json`) forwards `/api`
to `http://localhost:8000`, so a real backend needs to be running there
first:

```sh
cd ../deploy
docker compose -f docker-compose.yml -f docker-compose.dev.yml up -d --build db api
```

See `deploy/README.md`'s own "Local development" section for seeding an
admin (and a staff/part-timer account, a rate card, some inventory) into a
fresh box -- signing in needs at least the admin.

Then, from `dashboard/`:

```bash
ng serve
```

Once the server is running, open your browser and navigate to `http://localhost:4200/`. The application will automatically reload whenever you modify any of the source files.

## Code scaffolding

Angular CLI includes powerful code scaffolding tools. To generate a new component, run:

```bash
ng generate component component-name
```

For a complete list of available schematics (such as `components`, `directives`, or `pipes`), run:

```bash
ng generate --help
```

## Building

To build the project run:

```bash
ng build
```

This will compile your project and store the build artifacts in the `dist/` directory. By default, the production build optimizes your application for performance and speed.

## Running unit tests

To execute unit tests with the [Vitest](https://vitest.dev/) test runner, use the following command:

```bash
ng test
```

## Running end-to-end tests

For end-to-end (e2e) testing, run:

```bash
ng e2e
```

Angular CLI does not come with an end-to-end testing framework by default. You can choose one that suits your needs.

## Additional Resources

For more information on using the Angular CLI, including detailed command references, visit the [Angular CLI Overview and Command Reference](https://angular.dev/tools/cli) page.
