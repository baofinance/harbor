contract ThisExpression {
    function someFunc() public {}
    function someVeryVeryVeryLongVariableNameThatWillBeAccessedByThisKeyword() public {}

    function test() external {
        this.someFunc();
        this.someVeryVeryVeryLongVariableNameThatWillBeAccessedByThisKeyword();
        this.someVeryVeryVeryLongVariableNameThatWillBeAccessedByThisKeyword(); // comment1
        address(this).balance;

        address thisAddress = address(
            // comment2
            /* comment3 */ this // comment 4
        );
    }
}
