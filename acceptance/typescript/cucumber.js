export default {
  default: {
    import: ["dist/**/*.js"],
    paths: ["features/**/*.feature"],
    format: ["progress"],
    publishQuiet: true
  }
};
