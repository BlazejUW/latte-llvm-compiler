define i32 @main() { 
    %a = alloca i32 
    store i32 1, i32* %a 
    store i32 2, i32* %a
    ret i32 0
}