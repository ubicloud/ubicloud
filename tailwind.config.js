/** @type {import('tailwindcss').Config} */
module.exports = {
  content: [
    "./views/**/*.erb",
    "./assets/**/*.js",
  ],
  theme: {
    extend: {},
  },
  plugins: [
    require('@tailwindcss/forms'),
    require('@tailwindcss/typography'),
  ],
  safelist: [
    ...[...Array(101).keys()].flatMap(i => `w-[${i}%]`),
    {
      pattern: /bg-[a-z]+-500/,
    }
  ]
}
