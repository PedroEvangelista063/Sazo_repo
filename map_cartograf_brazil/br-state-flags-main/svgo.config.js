module.exports = {
  plugins: [
    'removeDimensions', // removes width/height so SVGs are scalable
    'removeXMLNS',      // removes redundant xmlns
    {
      name: 'preset-default',
      params: {
        overrides: {
          removeViewBox: false, // keep viewBox for scaling
        },
      },
    },
  ],
};
