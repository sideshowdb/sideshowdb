import { After } from "@cucumber/cucumber";
import { rm } from "node:fs/promises";

import { AcceptanceWorld } from "./world.js";

After(async function (this: AcceptanceWorld) {
  if (this.repoDir !== null) {
    await rm(this.repoDir, { recursive: true, force: true });
  }
});
