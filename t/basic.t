use strict;
use warnings;
use Test::More;
use Test::Fatal;

use Lexical::Multi::Sub;

{
    my $foo = do {
        multi foo ($x, $y) { $x ** $y }
        # FIXME: this should work without parens
        multi foo ($x) { foo($x, $x) }

        is exception {
            is foo(2, 4), 16;
            is foo(2), 4;
        }, undef;

        like exception { foo 2, 3, 4 }, qr/no variant/;

        ok !__PACKAGE__->can('foo');

        \&foo;
    };

    eval 'foo(2, 4)';
    like $@, qr/Undefined subroutine/;

    is exception {
        is $foo->(2), 4;
    }, undef;
}


{
    multi bar (Num $x) { bar int $x }
    multi bar (Int $x) { $x * 2 }

    is bar(2.0), 4;
    is bar(2.2), 4;
}

{
    multi baz (Int $x, Num $y) { }
    multi baz (Num $x, Int $y) { }

    like exception { baz 23, 42 }, qr/ambiguous/i;
}

{
    eval 'multi ($x) { $x }';
    like $@, qr/anon/i;
}

done_testing;
