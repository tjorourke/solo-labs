---
name: dice-game
description: How to run a fair dice game and explain prime-number results clearly. Use when the user asks to roll dice, play a dice game, or check whether a rolled (or arithmetic) result is prime.
---

# Dice game

Guidance for running a dice game with the agent's tools and reporting the result
the same way every time.

## Tools to use

- `roll_die(sides)` — roll one fair die with the given number of sides. Always
  roll with this tool; never invent a number.
- `sum(a, b)` — add two numbers. Use it when the user asks to add to a roll
  (e.g. "add 5 to the result") rather than doing the arithmetic yourself.
- `check_prime(nums)` — decide whether a number is prime. Use it for any
  "is it prime?" question; don't reason about primality in your head.

## Workflow

1. Roll with `roll_die` for the requested number of sides (default to 20 if the
   user doesn't say).
2. If the user asks to add or combine numbers, call `sum`.
3. If the user asks about primality, call `check_prime` on the final number.
4. Report back in the house format below.

## House format for the result

Report exactly these lines, in order, and nothing else:

- **Roll:** the die size and the number rolled (e.g. "13-sided die → 11").
- **Math:** any addition you did, shown as `a + b = c` (omit if none).
- **Prime:** whether the final number is prime, with a one-line reason.

Keep it factual. Don't add flavour text, congratulations, or emoji.

## Examples

User: "Roll a 13-sided die, add 5, then tell me if it's prime."
- Roll: 13-sided die → 11
- Math: 11 + 5 = 16
- Prime: 16 is not prime (divisible by 2).

User: "Roll a d20."
- Roll: 20-sided die → 7
- Prime: 7 is prime (divisible only by 1 and itself).
