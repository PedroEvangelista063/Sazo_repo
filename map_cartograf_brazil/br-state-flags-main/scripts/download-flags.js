import fs from "fs";
import path from "path";
import https from "https";

const OUT_DIR = "svgs/raw";

const FLAGS = {
  AC: "Flag_of_Acre.svg",
  AL: "Flag_of_Alagoas.svg",
  AP: "Flag_of_Amapá.svg",
  AM: "Flag_of_Amazonas.svg",
  BA: "Flag_of_Bahia.svg",
  CE: "Flag_of_Ceará.svg",
  DF: "Bandeira_do_Distrito_Federal_(Brasil).svg",
  ES: "Flag_of_Espírito_Santo.svg",
  GO: "Flag_of_Goiás.svg",
  MA: "Flag_of_Maranhão.svg",
  MT: "Flag_of_Mato_Grosso.svg",
  MS: "Flag_of_Mato_Grosso_do_Sul.svg",
  MG: "Flag_of_Minas_Gerais.svg",
  PA: "Flag_of_Pará.svg",
  PB: "Flag_of_Paraíba.svg",
  PR: "Flag_of_Paraná.svg",
  PE: "Flag_of_Pernambuco.svg",
  PI: "Flag_of_Piauí.svg",
  RJ: "Flag_of_Rio_de_Janeiro.svg",
  RN: "Flag_of_Rio_Grande_do_Norte.svg",
  RS: "Flag_of_Rio_Grande_do_Sul.svg",
  RO: "Flag_of_Rondônia.svg",
  RR: "Flag_of_Roraima.svg",
  SC: "Flag_of_Santa_Catarina.svg",
  SP: "Bandeira_do_estado_de_São_Paulo.svg",
  SE: "Flag_of_Sergipe.svg",
  TO: "Flag_of_Tocantins.svg",
};

const USER_AGENT =
  "br-state-flags/0.1 (https://github.com/arthurreira/br-state-flags)";

fs.mkdirSync(OUT_DIR, { recursive: true });

function fetchJson(url) {
  return new Promise((resolve, reject) => {
    https.get(
      url,
      {
        headers: {
          "User-Agent": USER_AGENT,
        },
      },
      (res) => {
        let data = "";
        res.on("data", (chunk) => (data += chunk));
        res.on("end", () => resolve(JSON.parse(data)));
      }
    ).on("error", reject);
  });
}

function downloadFile(url, outPath) {
  return new Promise((resolve, reject) => {
    https.get(
      url,
      {
        headers: {
          "User-Agent": USER_AGENT,
        },
      },
      (res) => {
        if (res.statusCode !== 200) {
          reject(new Error(`Download failed: ${res.statusCode}`));
          return;
        }
        const file = fs.createWriteStream(outPath);
        res.pipe(file);
        file.on("finish", () => file.close(resolve));
      }
    ).on("error", reject);
  });
}

(async () => {
  for (const [uf, fileName] of Object.entries(FLAGS)) {
    const outPath = path.join(OUT_DIR, `${uf.toLowerCase()}.svg`);

    // Skip if file already exists
    if (fs.existsSync(outPath)) {
      console.log(`Skipping ${uf}, file already exists.`);
      continue;
    }

    try {
      console.log(`Downloading ${uf}...`);

      const apiUrl =
        "https://commons.wikimedia.org/w/api.php" +
        `?action=query&titles=File:${encodeURIComponent(fileName)}` +
        "&prop=imageinfo&iiprop=url&format=json";

      const json = await fetchJson(apiUrl);
      const pages = Object.values(json.query.pages);
      const page = pages[0];

      if (!page.imageinfo || !page.imageinfo.length) {
        throw new Error("No imageinfo found (file name may be wrong)");
      }

      const imageUrl = page.imageinfo[0].url;

      await downloadFile(imageUrl, outPath);

      console.log(`  ✓ ${uf} saved`);
    } catch (err) {
      console.error(`  ✗ ${uf} failed`, err.message);
    }
  }
})();

