# useGraphEngine — bridging React to an imperative canvas engine (osionos)

> **In one sentence.** useGraphEngine is a [React hook](glossary.md#react-hook) that mounts a Canvas2D force-graph engine exactly once and keeps it wired to React props (model, controls, selection) through separate effects while protecting it from re-render churn via [refs](glossary.md#ref) and [stale-closure](glossary.md#stale-closure) tricks.

## What it is & why it exists

useGraphEngine bridges the worlds of React (where props change and components re-render) and an imperative Canvas2D graphics engine (where mounting cost is high and state lives in objects, not the component tree). The hook creates a [GraphEngine](glossary.md#graphengine) instance that owns two stacked canvas layers (aurora background + foreground graph), a d3-force physics simulator running in a [Web Worker](glossary.md#web-worker), and theme-aware rendering. It is the only React entrypoint to the framework-agnostic `@osionos/graph-engine` package, meaning it handles the messy lifecycle details—[ResizeObserver](glossary.md#resizeobserver) for sizing, [MutationObserver](glossary.md#mutationobserver) for theme changes, and a callbacks ref to avoid stale closures—so the engine can stay pure and untouched by React's declarative model.

## How it works

- On mount (empty useEffect dependency array), check that all three canvas refs are attached, read the user's [prefers-reduced-motion](glossary.md#prefers-reduced-motion) setting, and instantiate GraphEngine with those canvases and a themeRoot (the document element).
- Wrap the [EngineCallbacks](glossary.md#enginecallbacks) in a cbRef that gets updated every render (cbRef.current = args.callbacks), then pass callbacks that indirectly call through cbRef.current so they always see fresh closures—this avoids the engine capturing stale argument references.
- Attach a ResizeObserver to the container to measure size changes and call engine.setSize(), accounting for [device pixel ratio](glossary.md#device-pixel-ratio); call it once immediately to size the canvases.
- Attach a MutationObserver to document.documentElement watching data-theme, class, and style attributes; when theme changes fire, call engine.setTheme() to re-resolve CSS tokens.
- Call onReady(engine) if provided so the host can store the engine reference for imperative calls (zoom, fit, etc.).
- Return a [cleanup function](glossary.md#cleanup-function) that disconnects both observers, destroys the engine, and nulls out the engineRef.
- In four separate effects with specific [dependency arrays](glossary.md#dependency-array), call engine.setModel(), engine.setControls(), engine.setSelected(), and engine.setFocus() so updates to props flow into the engine without remounting it.
- Return the three refs (containerRef, bgRef, fgRef) and engineRef so the host can attach them to DOM elements and access the engine for imperative operations.

## The code that does it

**What to look at:** The mount effect creates one GraphEngine on empty deps, using cbRef to dodge stale closures; four separate effects sync model/controls/selection/focus downstream without remounting.

```ts
// apps/osionos/app/packages/graph-engine/src/react/useGraphEngine.ts:29-79
export function useGraphEngine(args: UseGraphEngineArgs): GraphEngineRefs {
  const containerRef = useRef<HTMLDivElement | null>(null);
  const bgRef = useRef<HTMLCanvasElement | null>(null);
  const fgRef = useRef<HTMLCanvasElement | null>(null);
  const engineRef = useRef<GraphEngine | null>(null);
  const cbRef = useRef<EngineCallbacks>(args.callbacks);
  cbRef.current = args.callbacks;

  useEffect(() => {
    const container = containerRef.current;
    const bg = bgRef.current;
    const fg = fgRef.current;
    if (!container || !bg || !fg) return;
    const reduced =
      typeof matchMedia === "function" && matchMedia("(prefers-reduced-motion: reduce)").matches;
    const engine = new GraphEngine({
      graphCanvas: fg,
      bgCanvas: bg,
      themeRoot: document.documentElement,
      reducedMotion: reduced,
      callbacks: {
        onSelect: (id) => cbRef.current.onSelect(id),
        onHover: (id) => cbRef.current.onHover(id),
        onExpand: (id) => cbRef.current.onExpand?.(id),
      },
    });
    engineRef.current = engine;

    const applySize = (): void => {
      const rect = container.getBoundingClientRect();
      engine.setSize(rect.width, rect.height, window.devicePixelRatio || 1);
    };
    applySize();
    const resize = new ResizeObserver(applySize);
    resize.observe(container);
    const themeWatcher = new MutationObserver(() => engine.setTheme());
    themeWatcher.observe(document.documentElement, {
      attributes: true,
      attributeFilter: ["data-theme", "class", "style"],
    });
    args.onReady?.(engine);

    return () => {
      resize.disconnect();
      themeWatcher.disconnect();
      engine.destroy();
      engineRef.current = null;
    };
    // Mount once; updates flow through the effects below.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);
```

**What to look at:** GraphView is the thin React wrapper that calls useGraphEngine, attaches the returned refs to the actual DOM elements, and passes through all stateless props (controls flow down, selection/hover callbacks flow up).

```tsx
// apps/osionos/app/packages/graph-engine/src/react/GraphView.tsx:28-54
export function GraphView(props: GraphViewProps): ReactElement {
  const { containerRef, bgRef, fgRef } = useGraphEngine({
    model: props.model,
    controls: props.controls,
    selectedId: props.selectedId ?? null,
    focusIds: props.focusIds ?? null,
    onReady: props.onReady,
    callbacks: {
      onSelect: props.onSelect ?? noop,
      onHover: props.onHover ?? noop,
      onExpand: props.onExpand,
    },
  });

  return (
    <div ref={containerRef} className={props.className ? `osio-graph ${props.className}` : "osio-graph"}>
      <canvas ref={bgRef} className="osio-graph__bg" aria-hidden="true" />
      <canvas
        ref={fgRef}
        className="osio-graph__fg"
        tabIndex={0}
        role="img"
        aria-label="Relationship graph"
      />
    </div>
  );
}
```

**What to look at:** GraphEngine owns the CanvasScene (graph layer) and AuroraBackground (animated backdrop), exposes imperative setSize/setModel/setControls/setTheme/setSelected/setFocus methods, and lazy-initializes the physics LayoutController on first model.

```ts
// apps/osionos/app/packages/graph-engine/src/core/engine.ts:42-80
export class GraphEngine {
  private readonly scene: CanvasScene;
  private readonly background: AuroraBackground;
  private readonly bgCanvas: HTMLCanvasElement;
  private layout: LayoutController | null = null;
  private controls: Controls = DEFAULT_CONTROLS;
  private width = 800;
  private height = 600;

  constructor(private readonly options: GraphEngineOptions) {
    const theme = resolveSceneTheme(options.themeRoot);
    this.bgCanvas = options.bgCanvas;
    this.background = new AuroraBackground(options.bgCanvas, theme, options.reducedMotion);
    this.scene = new CanvasScene(options.graphCanvas, theme, this.sceneCallbacks(), options.reducedMotion);
    this.background.start();
  }

  setSize(width: number, height: number, dpr: number): void {
    this.width = width;
    this.height = height;
    this.background.setSize(width, height, dpr);
    this.scene.setSize(width, height, dpr);
  }

  setModel(model: GraphModel): void {
    this.scene.setGraph(model);
    if (!this.layout) {
      this.layout = new LayoutController({
        width: this.width,
        height: this.height,
        params: this.controls.physics,
        onPositions: (x, y) => this.scene.setPositions(x, y),
        onSettled: () => this.scene.markLayoutSettled(),
      });
    }
    this.layout.rebuild(model);
    this.scene.setControls(this.controls);
  }
```

## Where it sits in the app

useGraphEngine sits between the React world (GraphView component accepting controls, model, and callbacks as props) and the imperative engine world (GraphEngine class managing rendering and interaction). The user clicks on nodes, model/controls stream in from state management, and selection/hover events flow back out through callbacks. The hook is the translation layer: React props arrive, the engine's imperative methods are called in response, and the engine reads live theme tokens from the DOM to stay visually coherent.

## Remember this

> One mount effect with empty deps creates the engine once; four separate update effects sync model, controls, selection, and focus without remounting it; cbRef tricks let you pass fresh callbacks into the engine without it capturing stale closures.

---
**See also:** [useAuth-client.md](useAuth-client.md) · [mail-bridge-client.md](mail-bridge-client.md) · [mail-cache.md](mail-cache.md) · [formula-engine-wasm.md](formula-engine-wasm.md) · [Glossary](glossary.md)
