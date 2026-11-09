const colors = require('tailwindcss/colors')
const plugin = require('tailwindcss/plugin')

const NEUTRALS = ['slate', 'gray', 'zinc', 'neutral', 'stone']
const HUES = [
  'red', 'orange', 'amber', 'yellow', 'lime', 'green', 'emerald', 'teal', 'cyan',
  'sky', 'blue', 'indigo', 'violet', 'purple', 'fuchsia', 'pink', 'rose',
]
const SHADES = [50, 100, 200, 300, 400, 500, 600, 700, 800, 900, 950]
const WHITE = '#ffffff'
const BLACK = '#000000'
const STONE = colors.stone
const SURFACE = STONE[900]

const channels = hex => [1, 3, 5].map(i => parseInt(hex.slice(i, i + 2), 16))
const mix = (hex, base, weight) => {
  const [a, b] = [channels(hex), channels(base)]
  return a.map((v, i) => Math.round(v * weight + b[i] * (1 - weight)))
}
const rgb = color => (typeof color === 'string' ? channels(color) : color).join(' ')

const DARK = {
  bg: {
    white: SURFACE,
    neutral: { 50: STONE[950], 100: STONE[800], 200: STONE[700], 300: STONE[600], 400: STONE[500] },
    hue: p => ({
      50: mix(p[500], SURFACE, 0.1),
      100: mix(p[500], SURFACE, 0.15),
      200: mix(p[500], SURFACE, 0.25),
      300: mix(p[500], SURFACE, 0.4),
    }),
  },
  text: {
    black: WHITE,
    neutral: {
      400: STONE[500], 500: STONE[400], 600: STONE[300], 700: STONE[300], 800: STONE[200], 900: STONE[100], 950: STONE[50],
    },
    hue: p => ({ 600: p[400], 700: p[300], 800: p[200], 900: p[100], 950: p[50] }),
  },
  line: {
    white: SURFACE,
    black: WHITE,
    neutral: {
      50: STONE[900], 100: mix(STONE[800], STONE[900], 0.5), 200: STONE[800], 300: STONE[700], 400: STONE[600],
      600: STONE[400], 700: STONE[300], 800: STONE[200], 900: STONE[100], 950: STONE[50],
    },
    hue: p => ({
      50: mix(p[500], SURFACE, 0.2),
      100: mix(p[500], SURFACE, 0.3),
      200: mix(p[500], SURFACE, 0.4),
      300: mix(p[500], SURFACE, 0.55),
    }),
  },
}

const darkVariables = {}

const themed = (name, light, dark) => {
  if (dark === undefined) return light
  darkVariables[`--dark-${name}`] = rgb(dark)
  return `rgb(var(--dark-${name}, ${rgb(light)}) / <alpha-value>)`
}

const family = (prefix, light, dark) =>
  Object.fromEntries(SHADES.filter(shade => light[shade]).map(shade => [shade, themed(`${prefix}-${shade}`, light[shade], dark[shade])]))

const palette = role => ({
  inherit: 'inherit',
  current: 'currentColor',
  transparent: 'transparent',
  black: themed(`${role}-black`, BLACK, DARK[role].black),
  white: themed(`${role}-white`, WHITE, DARK[role].white),
  ...Object.fromEntries(NEUTRALS.map(name => [name, family(`${role}-${name}`, colors[name], DARK[role].neutral)])),
  ...Object.fromEntries(HUES.map(name => [name, family(`${role}-${name}`, colors[name], DARK[role].hue(colors[name]))])),
})

const SIDEBAR_SHADES = [100, 200, 600, 700, 800]
const sidebar = family(
  'sidebar',
  Object.fromEntries(SIDEBAR_SHADES.map(shade => [shade, colors.orange[shade]])),
  { 100: STONE[300], 200: STONE[500], 600: STONE[900], 700: STONE[800], 800: STONE[700] },
)

const bg = palette('bg')
const text = palette('text')
const line = palette('line')
const opaque = value => value.replace(' / <alpha-value>', '')

/** @type {import('tailwindcss').Config} */
module.exports = {
  content: [
    "./views/**/*.erb",
    "./assets/**/*.js",
    "./helpers/web.rb",
  ],
  theme: {
    backgroundColor: { ...bg, sidebar },
    gradientColorStops: bg,
    textColor: { ...text, sidebar },
    placeholderColor: text,
    fill: text,
    stroke: text,
    borderColor: { ...line, DEFAULT: line.gray[200] },
    ringColor: { ...line, DEFAULT: colors.blue[500] },
    outlineColor: line,
    extend: {
      keyframes: {
        flash: {
          '0%, 100%': { backgroundColor: 'transparent' },
          '50%': { backgroundColor: opaque(bg.yellow[200]) },
        }
      },
      animation: {
        flash: 'flash 1s ease-in-out infinite',
      }
    },
  },
  plugins: [
    require('@tailwindcss/forms'),
    require('@tailwindcss/typography'),
    plugin(({ addBase }) => {
      addBase({
        '@media (prefers-color-scheme: dark)': {
          ':root': { colorScheme: 'dark', ...darkVariables },
          '*, ::before, ::after': { '--tw-ring-offset-color': opaque(bg.white) },
          'input, textarea, select': { backgroundColor: opaque(bg.white) },
          "input:where([type='checkbox'], [type='radio']):focus": { '--tw-ring-offset-color': opaque(bg.white) },
        },
      })
    }),
  ],
  safelist: [
    ...[...Array(101).keys()].flatMap(i => `w-[${i}%]`),
    {
      pattern: /bg-[a-z]+-500/,
    },
    ...['text-blue-600', 'text-green-400', 'text-amber-400', 'text-red-400',
    'text-sky-300', 'text-emerald-600', 'text-orange-500'],
    'transition-colors',
    'duration-1000',
    'border-red-500'
  ]
}
