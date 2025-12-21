---
title: Simple Javascript Theme Switcher Using Cookie
date: 2025-08-27
draft: false
tags:
  - javascript
  - theme-switcher
  - cookies
  - css
  - web-development
categories: 
  - tech
description: Learn how to implement a simple dark/light theme switcher for your website using JavaScript and cookies, leveraging the CSS invert filter for quick theme toggling.
---

As people become more aware of their eye health, dark theme has become so popular it almost becomes the standard color scheme for digital content nowadays, including blogs and static sites. Theme switching capability also becomes popular to be implemented on said media.

There are many ways to implement a theme switcher. The most common way is by having two separate CSS files, loading both CSS at the same time, then using JavaScript to modify the `class` properties of all elements. So, for example, when the user triggers the script to use dark theme, then each element's `class` properties will be appended with something like `-dark`; light theme will modify it to `-light`. But, what if I told you there is a simpler approach.

In this post, I'm going to show you how to create one using simple JavaScript and cookies.

# CSS Inversion Filter

The main idea behind the following approach is the [`invert()` CSS function](https://developer.mozilla.org/en-US/docs/Web/CSS/filter-function/invert) which will be applied to the page's `html` element.

```css
html {
  filter: invert(1)
}
```

The function will invert all the colors, including text, images, and background of every child element. So, we also need to make a reverse filter for certain children such as `<img>`, `<video>`, or `<code>`. This can be done by just re-applying the same inversion filter style

```javascript
document.querySelectorAll("img").forEach(el => {
  el.style = "filter: invert(1);"
})
```

# State Persistence with Cookie
To make the page remember the user's last chosen theme, we can simply use a cookie to store the value.

```javascript
document.cookie = "theme=" + newTheme + ";path=/"
```

If this theme switching method will be used for a multi-page website, it is important that the `path` value must be enforced to use the same value; in this case, it will be set to the root path (`/`), or else there will be multiple theme cookies for each page.

# Example Script
In the example below, we will create a simple implementation by making a button that will trigger the CSS inversion filter and cookie update.

First, we begin by defining the trigger button. Here is a simple button

```javascript
const btnSwitchTheme = document.getElementById("btn-switch-theme")
```
Then we create a helper function that will invert the theme. If we pass "light", it will return "dark", and vice versa:

```javascript
function invertTheme(theme) {
  return theme == "light" ? "dark" : "light"
}
```

Then we create the function to retrieve the `theme` cookie. It will get all the cookies from the browser then apply `map` and `filter` to get the specific cookie in which the key is `theme`. If none is found, return the default theme (light):

```javascript
function getTheme() {
  const cookies = Object.fromEntries(
    document.cookie.split("; ").map(c => c.split("="))
  );
  return cookies.theme || "light";
}
```

Next, we create a function to both update the trigger button's UI and the style of the `<html>` element:

```javascript
function applyTheme(toTheme) {
  btnSwitchTheme.textContent = "Switch to " + invertTheme(toTheme) + " theme"
  document.querySelector("html").style = toTheme == "dark" ? "filter: invert(1);" : ""
}
```

The last function is the click listener button when the trigger button is clicked:

```javascript
btnSwitchTheme.addEventListener("click", (event) => {
  const theme = getTheme()
  const newTheme = invertTheme(theme)
  document.cookie = "theme=" + newTheme + ";path=/"
  applyTheme(newTheme)
})
```

This will first check the current theme from the cookie, then update the theme cookie with the opposite theme, then call the `applyTheme()` function to update the button's UI and invert the `<html>` element's style.

To execute the script, we just need to create a `<script>` tag in the desired page, then call the `applyTheme()` to initialize the theme of this page when it is first loaded, passing the current theme cookie from the `getTheme()` function:

```javascript
<script>
  ...
  applyTheme(getTheme())
</script>
```

## Excluding Certain Child Elements

As I mentioned before, we also need to exclude some tags like `<img>` from inversion by re-applying the same CSS inversion filter for all instances of the tag

```javascript
  function neuralizeChildrenColor(child, toTheme) {
    document.querySelectorAll(child).forEach(el => {
      el.style = toTheme == "dark" ? "filter: invert(1);" : ""
    })
  }
```

By passing the name of the desired child tag to the child parameter, and what theme the page will change to (dark/light). Update the `applyTheme()` function:

```javascript
function applyTheme(toTheme) {
  btnSwitchTheme.textContent = "Switch to " + invertTheme(toTheme) + " theme"
  document.querySelector("html").style = toTheme == "dark" ? "filter: invert(1);" : ""
  neuralizeChildrenColor("img", toTheme)
  neuralizeChildrenColor(".highlight", toTheme)
}
```

# Wrap Up

Here is the complete script for this example:

```html
<script>
  const btnSwitchTheme = document.getElementById("btn-switch-theme")

  function getTheme() {
    const cookies = Object.fromEntries(
      document.cookie.split("; ").map(c => c.split("="))
    );
    return cookies.theme || "light";
  }

  function invertTheme(theme) {
    return theme == "light" ? "dark" : "light"
  }

  function applyTheme(toTheme) {
    btnSwitchTheme.textContent = "Switch to " + invertTheme(toTheme) + " theme"
    document.querySelector("html").style = toTheme == "dark" ? "filter: invert(1);" : ""
    neuralizeChildrenColor("img", toTheme)
  }

  function neuralizeChildrenColor(child, toTheme) {
    document.querySelectorAll(child).forEach(el => {
      el.style = toTheme == "dark" ? "filter: invert(1);" : ""
    })
  }

  btnSwitchTheme.addEventListener("click", (event) => {
    const theme = getTheme()
    const newTheme = invertTheme(theme)
    document.cookie = "theme=" + newTheme + ";path=/"
    applyTheme(newTheme)
  })

  applyTheme(getTheme())
</script>
``` 

# Flaw and Consideration

There is a flaw in this whole approach, which is it will also invert emojis. If your website is complex or uses emojis, consider using the common method of using two CSS files for the theme.




