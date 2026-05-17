const fs = require('fs');

const cloudSVG = `<svg viewBox="0 0 1200 400" xmlns="http://www.w3.org/2000/svg">
  <defs>
    <filter id="c-f" x="-20%" y="-20%" width="140%" height="140%">
      <feGaussianBlur stdDeviation="8" />
    </filter>
    <filter id="c-f2" x="-20%" y="-20%" width="140%" height="140%">
      <feGaussianBlur stdDeviation="3" />
    </filter>
  </defs>
  <g opacity="0.95">
    <g transform="translate(100, 100)">
      <circle cx="100" cy="80" r="50" fill="#fff" filter="url(#c-f)"/>
      <circle cx="160" cy="50" r="65" fill="#fff" filter="url(#c-f)"/>
      <circle cx="230" cy="70" r="55" fill="#fff" filter="url(#c-f)"/>
      <circle cx="160" cy="90" r="45" fill="#fff" filter="url(#c-f)"/>
      <circle cx="100" cy="80" r="50" fill="#fff" filter="url(#c-f2)"/>
      <circle cx="160" cy="50" r="65" fill="#fff" filter="url(#c-f2)"/>
      <circle cx="230" cy="70" r="55" fill="#fff" filter="url(#c-f2)"/>
      <circle cx="160" cy="90" r="45" fill="#fff" filter="url(#c-f2)"/>
    </g>
    <g transform="translate(650, 40) scale(0.8)">
      <circle cx="100" cy="80" r="50" fill="#fff" filter="url(#c-f)"/>
      <circle cx="160" cy="50" r="70" fill="#fff" filter="url(#c-f)"/>
      <circle cx="240" cy="70" r="60" fill="#fff" filter="url(#c-f)"/>
      <circle cx="280" cy="100" r="40" fill="#fff" filter="url(#c-f)"/>
      <circle cx="150" cy="100" r="45" fill="#fff" filter="url(#c-f)"/>
      <circle cx="100" cy="80" r="50" fill="#fff" filter="url(#c-f2)"/>
      <circle cx="160" cy="50" r="70" fill="#fff" filter="url(#c-f2)"/>
      <circle cx="240" cy="70" r="60" fill="#fff" filter="url(#c-f2)"/>
      <circle cx="280" cy="100" r="40" fill="#fff" filter="url(#c-f2)"/>
      <circle cx="150" cy="100" r="45" fill="#fff" filter="url(#c-f2)"/>
    </g>
    <g transform="translate(450, 200) scale(0.4)">
      <circle cx="100" cy="80" r="50" fill="#fff" filter="url(#c-f)"/>
      <circle cx="160" cy="50" r="70" fill="#fff" filter="url(#c-f)"/>
      <circle cx="240" cy="70" r="60" fill="#fff" filter="url(#c-f)"/>
    </g>
    <g transform="translate(950, 230) scale(0.5)">
      <circle cx="100" cy="80" r="50" fill="#fff" filter="url(#c-f)"/>
      <circle cx="160" cy="50" r="70" fill="#fff" filter="url(#c-f)"/>
      <circle cx="240" cy="70" r="60" fill="#fff" filter="url(#c-f)"/>
    </g>
  </g>
</svg>`;

const hillSVG = `<svg viewBox="0 0 1000 600" preserveAspectRatio="none" xmlns="http://www.w3.org/2000/svg">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1"><stop offset="0%" stop-color="#3c6f2a"/><stop offset="100%" stop-color="#1b3d11"/></linearGradient>
    <linearGradient id="mg" x1="0" y1="0" x2="0" y2="1"><stop offset="0%" stop-color="#559933"/><stop offset="100%" stop-color="#225511"/></linearGradient>
    <linearGradient id="fg" x1="0" y1="0" x2="0" y2="1"><stop offset="0%" stop-color="#6bc23b"/><stop offset="100%" stop-color="#2a7711"/></linearGradient>
    <filter id="f" x="-20%" y="-20%" width="140%" height="140%"><feGaussianBlur stdDeviation="30" /></filter>
  </defs>
  <path d="M-100,600 L-100,200 C200,-50 400,500 700,300 C900,150 1000,250 1200,100 L1200,800 Z" fill="url(#bg)" filter="url(#f)" />
  <path d="M-100,600 L-100,450 C250,600 450,-50 850,300 C1000,450 1050,350 1200,300 L1200,800 Z" fill="url(#mg)" filter="url(#f)" opacity="0.9" />
  <path d="M-100,600 L-100,600 C200,200 600,750 1200,350 L1200,800 Z" fill="url(#fg)" filter="url(#f)" opacity="0.95"/>
</svg>`;

const cloudU = "url('data:image/svg+xml," + cloudSVG.replace(/'/g, '"').replace(/#/g, "%23").replace(/\n/g, '').replace(/\s+/g, ' ') + "')";
const hillU = "url('data:image/svg+xml," + hillSVG.replace(/'/g, '"').replace(/#/g, "%23").replace(/\n/g, '').replace(/\s+/g, ' ') + "')";

let css = fs.readFileSync('src/index.css', 'utf8');

css = css.replace(/\.cloud-layer \{[\s\S]*?\}/, 
  [
    ".cloud-layer {",
    "  position: absolute;",
    "  top: 0;",
    "  left: 0;",
    "  height: 100%;",
    "  width: 200%;",
    "  background-image: " + cloudU + ";",
    "  background-size: 1500px 100%;",
    "  background-repeat: repeat-x;",
    "  animation: slideClouds 45s linear infinite;",
    "}"
  ].join("\n")
);

css = css.replace(/\.bliss-clouds \{[\s\S]*?\}/, 
  [
    ".bliss-clouds {",
    "  position: absolute;",
    "  top: 0;",
    "  left: 0;",
    "  height: 60%;",
    "  width: 200%;",
    "  background-image: " + cloudU + ";",
    "  background-size: 1500px 100%;",
    "  background-repeat: repeat-x;",
    "  animation: slideCloudsBliss 45s linear infinite;",
    "}"
  ].join("\n")
);

css = css.replace(/\.bliss-hill \{[\s\S]*?\}/, 
  [
    ".bliss-hill {",
    "  position: absolute;",
    "  bottom: -2%;",
    "  left: -2%;",
    "  width: 104%;",
    "  height: 60%;",
    "  background-image: " + hillU + ";",
    "  background-size: 100% 100%;",
    "}"
  ].join("\n")
);

fs.writeFileSync('src/index.css', css);
