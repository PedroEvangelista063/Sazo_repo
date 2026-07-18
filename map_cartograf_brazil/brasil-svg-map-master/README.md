# Brazil React SVG MAP

- A React component Map of Brazil using SVG

## Props Definition

| Prop        | Description       | type   | default | isRequired |
| ----------- | ----------------- | ------ | ------- | ---------- |
| mapWidth    | Width of Map      | number | 500     | yes        |
| mapHeight   | Height of Map     | number | 500     | yes        |
| bgFillColor | Background of Map | string | #EFEFEF | no         |

## Install and Run

- npm install
- npm run build
- npm run build:watch

> create a react app to test.
> use `npm link brasil-svg-map` to link as node_modules package
> import { Brazil } from 'brasil-svg-map'


### TO DO

> Features

- ~Mouseover change Color of each city~.
- onClick Select City.
- Tooltip for each city when hover.

> Building

- Use webpack to handle with production env.
- adding css or styled-componets to future styling.
