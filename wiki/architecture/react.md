REACT is considered by most of people as a framework. his main purpose is to build a user interface.


> key insight: Components + JSX + State + Props + Virtual DOM + Rendu Declaratif.

# The components
React cut up the interfaces in small blocs independently called components
instead of writing one big page HTML.
chaque composant possède sa propre logique et son propre affichage.

Exemple:
```typescript
function Button() {
    return <button>Clique-moi</button>;
}
```

le composant doit être réutilisé partout.

## 2. JSX

React utilise le JSX, qui mélange JavaScript et HTML.
```typescript

funciton App()
{
    return (<h1>Bonjour</h1>);
}

```

Même si ça ressemble à du HTML, c'est du JavaScript.

Le navigateur ne comprend pas directement la JSX. Il est transformé en :
React.createElement("h1", null, "bonjour");


# Le Virtual DOM

It's the most known characteristics the most known.

Without REACT: we modify the real DOM and navigator recalculate the page.
with REACT the server of react use a `Virtual DOM` + comparison (Diffing) + Only the necessary changes to the DOM reel

# PROPS
The props allow to trasmit the data of a component parent to a component children

```typescript
function User(props) {
    return <h2>{props.name}</h2>
}

```

use:
```typescript
<User name="Alice"/>
<User name="Bob" />
```

we can see the props like function parameters



# The State
The state represent the datas that can change

```typescript
const [count, setCount] = useState(0);
```

Cuando the state change:
```typescript
<button onClick={() =>
    setCount(count + 1))}>
        {count}
    </button>
```

each click is put 
# The declaratif render
in Javascript classic:

```javascript
if (connected)
{
    document.getElementById("status").innerHTML = "Connedtec";
}

```


in react:
```javascript
return  (
    connected
        ? <h1>Connected</h1>
        : <h1>Disconnected</h1>
)
``` 

# The hooks
the hooks allow to add the functionnalities of functional components.

The most known are :
- `useState` -> hold the datas
- `useEffect` -> run the edgecases (appel, API, timer, etc.)
- useContext -> share global state datas
- useMemo -> optimize the cost of calcul useCallBack -> memorize a function

Exemple:
```typescript
useEffect(() => {
    console.log("Le composant est monté");
}, []);

```


# one way data flow
the datas flow from to parent to child

the children mobilize directly the data of the parent. it renders the app more previsible and easier to debug..

# the reusability

A compoennt can be reusable  as many times as we need:

<Card title="Produit A">
<Card title="Produit B">
<Card title="Produit C">
# a system ecoflexible
# 
