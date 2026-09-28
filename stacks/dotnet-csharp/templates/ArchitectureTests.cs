using NetArchTest.Rules;
using Xunit;

namespace MyApp.ArchitectureTests;

// bdd-gates: the hexagonal boundary as a failing test, not a paragraph.
// Set the marker type, core namespace, and forbidden dependencies for this repo.
public class ArchitectureBoundaryTests
{
    private static readonly string[] ForbiddenInCore =
    {
        "Microsoft.AspNetCore",
        "Microsoft.EntityFrameworkCore",
        "LibGit2Sharp",
        "System.Net.Http",
    };

    [Fact]
    public void Core_depends_on_no_framework_or_infrastructure()
    {
        var result = Types.InAssembly(typeof(MyApp.Domain.AssemblyMarker).Assembly)
            .That().ResideInNamespace("MyApp.Domain")
            .ShouldNot().HaveDependencyOnAny(ForbiddenInCore)
            .GetResult();

        Assert.True(result.IsSuccessful,
            "Core types with forbidden dependencies: " + string.Join(", ", result.FailingTypeNames ?? []));
    }
}
