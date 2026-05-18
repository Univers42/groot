# JavaScript & TypeScript Module Cheat Sheet

## 1. Extension Breakdown
* **`.js`**: Dynamic. Defaults to CommonJS (`require`), unless configured otherwise.
* **`.mjs`**: ES Module. Forces Node.js/browsers to use modern `import`/`export`.
* **`.cjs`**: CommonJS. Forces Node.js to use legacy `require` syntax.
* **`.ts`**: TypeScript. Modern industry standard for code logic.
* **`.tsx`**: TypeScript React. Standard extension for React components.

## 2. JavaScript Strategy
You do not need to switch everything to `.mjs`. Choose one approach:

### The Modern Way (Recommended)
Keep using `.js` files, but add this line to your **`package.json`**:
```json
"type": "module"
```
* **Result:** All `.js` files now support modern `import`/`export` natively.

### The Legacy Way
If you have an old project using `require()`:
* Keep using `.js` for legacy code.
* Use `.mjs` **only** for new files where you want `import`/`export`.

## 3. TypeScript Strategy
If you use **`.ts`** and **`.tsx`**, you do not need to worry about `.mjs` or `.cjs`. 
* **Universal Syntax:** You always write modern `import`/`export`.
* **Auto-Compilation:** Your bundler (Vite, Next.js) auto-converts files to the correct target format.

### Recommended `tsconfig.json`
```json
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "NodeNext",
    "moduleResolution": "NodeNext",
    "esModuleInterop": true,
    "strict": true
  }
}
```

## Summary Checklist
* **TypeScript project?** Use `.ts` and `.tsx`.
* **New JS project?** Use `.js` + `"type": "module"` in `package.json`.
* **Old JS project?** Use `.js` for old files, `.mjs` for new module files.
