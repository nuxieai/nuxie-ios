# Native group installation

SDK-authored fixture, generated without a publisher or runtime build. Regenerate with `python3 generate.py`. Both SDKs keep identical bytes.

The canonical policy declares required email and optional unconstrained name. It retains both group members. Native installation must retain only email because name has neither a rule nor an empty-value marker. The native name errors list stays empty. After writing `person@example.test` and `Ada`, validation is true and save capture contains both answers. Removing email's rule makes the installed group empty; the group itself must still be installed and valid.

This fixture supplements the published F5 proofs. It does not replace or modify F5.
