@freestanding(expression)
public macro fortyTwo() -> Int = #externalMacro(
    module: "FocusedMacros",
    type: "FortyTwoMacro"
)

public let macroAnswer = #fortyTwo()
