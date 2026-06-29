# Better tooling

because Typescript understand code, the editor can provide:
- intelligent autocomplete
- go to definition
- find all references
- rename symbols safely
- inline documentation
- better error detection while typing

**example**:
```typescript
function calculatePrice(price:number, tax:number) {
    return (price + tax);
}

```

without typescript :
function createUser(user) {
    ...
}

- what's inside user ?
- does it have a name ?
- email?
- age ?

with typescript:

```bash
interface User {
    name: string;
    email: string;
    age: number;
}

function createUser(user: User) {}
```

the function explains itself

## Catching bugs beofre it's running
``` typescript
const user = {
    name: "Alice"
};
console.logj(user.age);

``` 

## 5. Better API design

Typescript lets you express what is allowed.

Example:

```typescript
type Theme = "light" | "dark";
``` 

Now:

```typescript
setTheme("light");
setTheme("Dark");
setTheme("blue");
```

### 6 Powerful type system 

typescript isn't just about string and number.

it has advanceed features like:
- Generics
- Union types
- intersection types
- conditinal types
- mapped types
- template literal types

```typescript
type Result =
    | { success: true; data: string }
    | { success: false; error: string}
``` 

## 7. safer collaboration

## 8. easier onboarding