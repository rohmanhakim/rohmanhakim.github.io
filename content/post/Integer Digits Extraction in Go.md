---
title: "Integer Digits Extraction in Go"
date: 2026-06-04
draft: false
categories:
    - programming
tags:
    - programming
    - go
    - data-structure-algorithm
summary: "A post exploring different approach of digits extraction in GO."
description: "A post exploring different approach of digits extraction in GO."
---

Sometimes a programming problem need you to extract the digits from an integer number.

For example given an integer `1234` you want to examine `1`, `2`, `3` and `4` independently.

There are several methods on how to do it:

## Method 1: Least-significant-first / LSF (reverse order)

```go
digits := []int{}
for n > 0 {
    digits = append(digits, n%10)
    n /= 10
}
// 1234 → [4, 3, 2, 1]
```

This is the **natural** way the math works. `% 10` always peels off the rightmost digit. It's the fastest and simplest extraction, but we get digits backwards.

**Use when:** order doesn't matter (e.g. digit sum, digit frequency counts).

## Method 2: Most-significant-first / MSF via prepend

```go
digits := []int{}
for n > 0 {
    digits = append([]int{n % 10}, digits...)
    n /= 10
}
// 1234 → [1, 2, 3, 4]
```

We still peel from the right, but prepend each digit to the front. Correct order, but each prepend allocates a **new backing array** and copies all existing elements forward.

This would give us **O(D²)** in allocations where D is digit count. Fine for 6-digit numbers, but it's the worst of the MSF options.

**Use when:** we want readable one-pass code and D is small.

## Method 3: Most-significant-first via extract-then-reverse

```go
digits := []int{}
for n > 0 {
    digits = append(digits, n%10)
    n /= 10
}
// reverse in-place
for l, r := 0, len(digits)-1; l < r; l, r = l+1, r-1 {
    digits[l], digits[r] = digits[r], digits[l]
}
// 1234 → [1, 2, 3, 4]
```

Extract LSF first (fast, no allocs beyond the initial slice), then reverse in-place. The reversal is O(D) with zero allocations. This is the **most performant** pure-integer approach.

**Use when:** we need correct order and care about allocations (e.g. called in a tight loop).

## Method 4: Most-significant-first via `strconv.Itoa`

```go
import "strconv"

s := strconv.Itoa(n)
// s[i] is a byte: '0'=48, '1'=49, ... '9'=57
// 1234 → s = "1234", s[0]='1', s[1]='2', ...
```

We skip extraction entirely. 

The string is already in correct order. Byte comparisons work correctly since `'0' < '1' < ... < '9'`. To get the actual integer value of a digit: `int(s[i] - '0')`.

One allocation (the string), but it's a single contiguous one. Often the cleanest for problems where we're **traversing** digits rather than doing arithmetic on them.

**Use when:** we're comparing or indexing digits (peaks/valleys, palindrome check, adjacent difference), and don't need them as integers.

## Comparisons

| Method                        | Order    | Allocations | Best for                                   |
| ----------------------------- | -------- | ----------- | ------------------------------------------ |
| LSF (`% 10` + append)         | Reversed | 1 (slice)   | Digit sum, frequency, order doesn't matter |
| Prepend (`[]int{d}, rest...`) | Correct  | O(D²)       | Readable code, small D                     |
| Extract + reverse in-place    | Correct  | 1 (slice)   | Performance-sensitive, need integers       |
| `strconv.Itoa`                | Correct  | 1 (string)  | Traversal/comparison, cleaner code         |

## Case Study

Let's use some problems from leetcode that involves digits extraction

### 3300. Minimum Element After Replacement With Digit Sum

[Problem's link](https://leetcode.com/problems/minimum-element-after-replacement-with-digit-sum/description/)

```
You are given an integer array `nums`.
You replace each element in nums with the sum of its digits.
Return the minimum element in nums after all replacements.

Example 1:

Input: nums = [10,12,13,14]
Output: 1
Explanation:
nums becomes [1, 3, 4, 5] after all replacements, with minimum element 1.

Example 2:
Input: nums = [1,2,3,4]
Output: 1
Explanation:
nums becomes [1, 2, 3, 4] after all replacements, with minimum element 1.

Example 3:
Input: nums = [999,19,199]
Output: 10
Explanation:
nums becomes [27, 10, 19] after all replacements, with minimum element 10.

Constraints:
- 1 <= nums.length <= 100
- 1 <= nums[i] <= 10^4
```

This problem is a pure application of the LSF digit extraction we're just discussed.

We only need the digit _values_ for arithmetic (summing), **order is irrelevant**, so we can just use LSF with a running accumulator. No slice needed at all.

```go
func minElement(nums []int) int {
    min := math.MaxInt32
    for _, n := range nums {
        sum := 0
        for n > 0 {
            digit := n % 10
            sum = sum + digit
            n = n / 10
        }

        if sum < min {
            min = sum
        }
    }
    return min
}
```

In the algorithm, we accumulate directly into `sum` rather than collecting into a slice first. Then only build a slice when we actually need to index or traverse digits in order.

### 2553. Separate the Digits in an Array

[Problem's link](https://leetcode.com/problems/separate-the-digits-in-an-array/description/)

```
Given an array of positive integers `nums`, return an array `answer` that consists of the digits of each integer in nums after separating them in the same order they appear in nums.

To separate the digits of an integer is to get all the digits it has in the same order.

- For example, for the integer 10921, the separation of its digits is [1,0,9,2,1].

Example 1:
Input: nums = [13,25,83,77]
Output: [1,3,2,5,8,3,7,7]
Explanation:
- The separation of 13 is [1,3].
- The separation of 25 is [2,5].
- The separation of 83 is [8,3].
- The separation of 77 is [7,7].
answer = [1,3,2,5,8,3,7,7]. Note that answer contains the separations in the same order.

Example 2:
Input: nums = [7,1,3,9]
Output: [7,1,3,9]
Explanation: The separation of each integer in nums is itself.
answer = [7,1,3,9].

Constraints:
- 1 <= nums.length <= 1000
- 1 <= nums[i] <= 10^5
```

We can extract LSF into a temp slice, then drain it in reverse into the output:

```go
func separateDigits(nums []int) []int {
    out := []int{}
    for _, num := range nums {
        res := []int{}
        x := num
        for x != 0 {
            digit := x % 10
            x = x / 10
            res = append(res, digit)
        }
        for len(res) != 0 {
            out = append(out, res[len(res)-1])
            res = res[:len(res)-1]
        }
    }
    return out
}
```

In this approach, the only thing worth flagging is the draining loop. We're manually popping from `res` to reverse it, which is valid but verbose. This is exactly where the **extract + reverse in-place** pattern from our earlier discussion:

```go
func separateDigits(nums []int) []int {
    out := []int{}
    for _, num := range nums {
        res := []int{}
        for num > 0 {
            res = append(res, num%10)
            num /= 10
        }
        // reverse in-place
        for l, r := 0, len(res)-1; l < r; l, r = l+1, r-1 {
            res[l], res[r] = res[r], res[l]
        }
        out = append(out, res...)
    }
    return out
}
```

`res...` to append a slice into another slice is also worth having as a reflex. It's cleaner than a manual loop. 

Alternatively, since we're just traversing digits in order without arithmetic, `strconv.Itoa` is arguably the cleanest here:
```go
func separateDigits(nums []int) []int {
    out := []int{}
    for _, num := range nums {
        for _, ch := range strconv.Itoa(num) { 
            out = append(out, int(ch-'0'))
        }
    }
    return out
}
```
No temp slice at all. The `int(ch - '0')` conversion is the idiom for turning a digit rune into its integer value.

### 7. Reverse Integer

[Problem's link](https://leetcode.com/problems/reverse-integer/)

```
Given a signed 32-bit integer `x`, return x with its digits reversed. If reversing x causes the value to go outside the signed 32-bit integer range [-2^31, 2^31 - 1], then return 0.

Assume the environment does not allow you to store 64-bit integers (signed or unsigned).

Example 1:
Input: x = 123
Output: 321

Example 2:
Input: x = -123
Output: -321

Example 3:
Input: x = 120
Output: 21

Constraints:
- -2^31 <= x <= 2^31 - 1
```

This one has a twist: the overflow constraint makes it more interesting than a standard reversal.

The naive approach : 
extract all digits -> reverse -> reconstruct

but this requires storing the full reversed number before checking overflow, which is too late. 

```go

func reverse(x int) int {
    sign := 1
    if x < 0 {
        sign = -1
    }

    remaining := x * sign
    sum := 0

    for remaining != 0 {
        currentDigit := remaining % 10
        remaining = remaining / 10
        
        sum = sum*10 + currentDigit // ---> no guard will cause overflow!
    }

    return sum * sign
}
```

We must add guard before accumulate the sum:

```go
func reverse(x int) int {
    sign := 1
    if x < 0 {
        sign = -1
    }
    remaining := x * sign
    sum := 0
    for remaining != 0 {
        digit := remaining % 10
        remaining /= 10

        // check before multiplying
        if sum > math.MaxInt32/10 || (sum == math.MaxInt32/10 && digit > 7) {
            return 0
        }

        sum = sum*10 + digit
    }
    return sum * sign
}
```

The cleaner approach is using a trick is to **build the reversed number digit by digit and check overflow before each multiplication**:

```go
func reverse(x int) int {
    result := 0
    for x != 0 {
        digit := x % 10
        x /= 10

        // check before result*10 overflows
        if result > math.MaxInt32/10 || (result == math.MaxInt32/10 && digit > 7) {
            return 0
        }
        if result < math.MinInt32/10 || (result == math.MinInt32/10 && digit < -8) {
            return 0
        }
        result = result*10 + digit
    }
    return result
}
```

**Why `digit > 7` and `digit < -8`?**

`math.MaxInt32` is `2147483647` -> the last digit is `7`. So if `result` is already at `MaxInt32/10 = 214748364`, any digit > 7 would push it over. Similarly `math.MinInt32` is `-2147483648` -> the last digit is `8` (in magnitude), so the bound is `-8`.

**Negative numbers work automatically** because Go's `%` operator preserves the sign of the dividend . For example: `-123 % 10 = -3`, so digits come out negative and the result accumulates correctly with the same logic.

**The key insight to internalize:** whenever a problem says "check for overflow," the pattern is to check _before_ the operation that would overflow, not after. Here that means checking before `result*10 + digit` rather than after.

### 3751. Total Waviness of Numbers in Range I

[Problem's link](https://leetcode.com/problems/total-waviness-of-numbers-in-range-i/)

```
You are given two integers `num1` and `num2` representing an inclusive range [num1, num2].

The "waviness" of a number is defined as the total count of its "peaks" and "valleys":

- A digit is a "peak" if it is strictly greater than both of its immediate neighbors.
- A digit is a "valley" if it is strictly less than both of its immediate neighbors.
- The first and last digits of a number cannot be peaks or valleys.
- Any number with fewer than 3 digits has a waviness of 0.

Return the total sum of waviness for all numbers in the range [num1, num2].

Example 1:
Input: num1 = 120, num2 = 130
Output: 3
Explanation:
- In the range [120, 130]:
	- 120: middle digit 2 is a peak, waviness = 1.
	- 121: middle digit 2 is a peak, waviness = 1.
	- 130: middle digit 3 is a peak, waviness = 1.
	- All other numbers in the range have a waviness of 0.
- Thus, total waviness is 1 + 1 + 1 = 3.

Example 2:
Input: num1 = 198, num2 = 202
Output: 3
Explanation:
- In the range [198, 202]:
	- 198: middle digit 9 is a peak, waviness = 1.
	- 201: middle digit 0 is a valley, waviness = 1.
	- 202: middle digit 0 is a valley, waviness = 1.
	- All other numbers in the range have a waviness of 0.
- Thus, total waviness is 1 + 1 + 1 = 3.

Example 3:
Input: num1 = 4848, num2 = 4848
Output: 2
Explanation:
- Number 4848: the second digit 8 is a peak, and the third digit 4 is a valley, giving a waviness of 2.

Constraints:
- 1 <= num1 <= num2 <= 10^5
```

We can build digits by repeatedly taking `% 10`, which gives us digits in LSF order: For `120`, we'll get `[0, 2, 1]` instead of `[1, 2, 0]`. The peak/valley check will still works here, reversing doesn't change whether a middle digit is a peak/valley.

```go
func totalWaviness(num1 int, num2 int) int {
    total := 0
    for n := num1; n <= num2; n++ {
        number := n
        digits := []int{}
        for number > 0 {
            digits = append(digits, number%10)
            number = number / 10
        }
        waviness := 0
        if len(digits) >= 3 {
            for i := 1; i < len(digits)-1; i++ {
                peak := digits[i] > digits[i-1] && digits[i] > digits[i+1]
                valley := digits[i] < digits[i-1] && digits[i] < digits[i+1]
                if peak || valley {
                    waviness++
                }
            }
        }
        total += waviness
    }
    return total
}
```

This approach has **O((num2 - num1) * D)** where D is the number of digits (at most 6 for 10^5). Given the constraint `num2 <= 10^5`, the range is at most 100,000 numbers, each with at most 6 digits, so it's fast enough in practice. There's no fundamentally better algorithmic approach for this problem. We have to inspect every number. The brute force _is_ the intended solution here.

That said, there is another approach using `strconv.Itoa` that is worth knowing:

```go
func waviness(n int) int {
    s := strconv.Itoa(n)
    count := 0
    for i := 1; i < len(s)-1; i++ {
        if s[i] > s[i-1] && s[i] > s[i+1] {
            count++
        } else if s[i] < s[i-1] && s[i] < s[i+1] {
            count++
        }
    }
    return count
}
```

This is arguably the cleanest version. Digit order is naturally correct, no manual extraction needed, and byte comparison works correctly since `'0'`–`'9'` are ordered.

## Conclusion

Digits extraction have many tools. Pick the right one depending on the problem.

| Situation                                   | Method                                                      |
| ------------------------------------------- | ----------------------------------------------------------- |
| Order doesn't matter (digit sum, frequency) | LSF with running accumulator --> no slice needed            |
| Need digits as integers in correct order    | Extract LSF --> reverse in-place                            |
| Need to traverse/compare digits in order    | `strconv.Itoa`--> skip extraction entirely                  |
| Avoid                                       | Prepend `append([]int{d}, rest...)` --> hidden O(D²) allocs |

### Only collect into a slice when we actually need to index

In Leetcode #3300.  The naive approach's `minElement` is a good instinct. That habit generalizes: ask ourself _"do we need to index these digits, or just consume them?"_ before reaching for a slice.

### Overflow: check before the operation, not after

Lesson from Leetcode #7 : 
The core rule: if an operation can overflow, check its inputs **before** executing it, not the result after.

```go
// wrong — overflow already happened
sum = sum*10 + digit
if sum > math.MaxInt32 { ... }

// right — check before multiplying
if sum > math.MaxInt32/10 || (sum == math.MaxInt32/10 && digit > 7) {
    return 0
}
sum = sum*10 + digit
```

This applies beyond digit problems. Any time we're building up a number incrementally.

### The `MaxInt32` boundary digits are worth memorizing

- `math.MaxInt32 = 2147483647` --> last digit **7**
- `math.MinInt32 = -2147483648` --> last digit **-8**

These show up in overflow checks often enough that recognizing them on sight saves time.

### Sign separation is a clean pattern for signed integer problems

Isolate the sign upfront, work with the magnitude, reapply at the end. It simplifies both the logic and the overflow checks (positive bounds only).