import { Component } from '@angular/core';
import { RouterOutlet } from '@angular/router';

/**
 * The shell. Deliberately empty: every screen owns its own layout, and a
 * chrome that every page has to fit inside is the thing that makes the third
 * screen awkward.
 */
@Component({
  selector: 'app-root',
  imports: [RouterOutlet],
  templateUrl: './app.html',
  styleUrl: './app.css',
})
export class App {}
