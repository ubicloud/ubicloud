/** @type {import('tailwindcss').Config} */
module.exports = {
  content: [
    "./views/**/*.erb",
    "./assets/**/*.js",
    "./helpers/web.rb",
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
    },
    ...['text-blue-600', 'text-green-400', 'text-amber-400', 'text-red-400',
    'text-sky-300', 'text-emerald-600', 'text-orange-500'],
  ]
}
