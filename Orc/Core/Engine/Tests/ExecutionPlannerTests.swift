import Testing
import Models
@testable import Engine

/// Tests for ExecutionPlanner — DAG resolution and topological ordering.
struct ExecutionPlannerTests {

    let planner = ExecutionPlanner()

    // MARK: - Linear Chain

    @Test("Linear chain: A -> B -> C produces correct topological order")
    func linearChain() throws {
        let workflow = Workflow(
            name: "linear",
            nodes: [
                Models.Node(id: "A", agent: .literal("fake"), prompt: "a"),
                Models.Node(id: "B", agent: .literal("fake"), prompt: "b", dependsOn: ["A"]),
                Models.Node(id: "C", agent: .literal("fake"), prompt: "c", dependsOn: ["B"]),
            ]
        )

        let plan = try planner.plan(workflow: workflow)

        // A must come before B, B before C.
        let indexA = plan.topologicalOrder.firstIndex(of: "A")!
        let indexB = plan.topologicalOrder.firstIndex(of: "B")!
        let indexC = plan.topologicalOrder.firstIndex(of: "C")!

        #expect(indexA < indexB)
        #expect(indexB < indexC)
    }

    // MARK: - Diamond DAG

    @Test("Diamond: A -> B,C -> D produces valid topological order")
    func diamondDAG() throws {
        let workflow = Workflow(
            name: "diamond",
            nodes: [
                Models.Node(id: "A", agent: .literal("fake"), prompt: "a"),
                Models.Node(id: "B", agent: .literal("fake"), prompt: "b", dependsOn: ["A"]),
                Models.Node(id: "C", agent: .literal("fake"), prompt: "c", dependsOn: ["A"]),
                Models.Node(id: "D", agent: .literal("fake"), prompt: "d", dependsOn: ["B", "C"]),
            ]
        )

        let plan = try planner.plan(workflow: workflow)

        let indexA = plan.topologicalOrder.firstIndex(of: "A")!
        let indexB = plan.topologicalOrder.firstIndex(of: "B")!
        let indexC = plan.topologicalOrder.firstIndex(of: "C")!
        let indexD = plan.topologicalOrder.firstIndex(of: "D")!

        #expect(indexA < indexB)
        #expect(indexA < indexC)
        #expect(indexB < indexD)
        #expect(indexC < indexD)
    }

    // MARK: - Fan-out / Fan-in

    @Test("Fan-out then fan-in: A -> B,C,D -> E")
    func fanOutFanIn() throws {
        let workflow = Workflow(
            name: "fan",
            nodes: [
                Models.Node(id: "A", agent: .literal("fake"), prompt: "a"),
                Models.Node(id: "B", agent: .literal("fake"), prompt: "b", dependsOn: ["A"]),
                Models.Node(id: "C", agent: .literal("fake"), prompt: "c", dependsOn: ["A"]),
                Models.Node(id: "D", agent: .literal("fake"), prompt: "d", dependsOn: ["A"]),
                Models.Node(id: "E", agent: .literal("fake"), prompt: "e", dependsOn: ["B", "C", "D"]),
            ]
        )

        let plan = try planner.plan(workflow: workflow)

        let indexA = plan.topologicalOrder.firstIndex(of: "A")!
        let indexE = plan.topologicalOrder.firstIndex(of: "E")!

        #expect(indexA < indexE)
        // B, C, D are all between A and E.
        for id in ["B", "C", "D"] {
            let idx = plan.topologicalOrder.firstIndex(of: id)!
            #expect(indexA < idx)
            #expect(idx < indexE)
        }
    }

    // MARK: - Disconnected Parallel Branches

    @Test("Disconnected parallel branches are both included")
    func disconnectedBranches() throws {
        let workflow = Workflow(
            name: "parallel",
            nodes: [
                Models.Node(id: "A", agent: .literal("fake"), prompt: "a"),
                Models.Node(id: "B", agent: .literal("fake"), prompt: "b", dependsOn: ["A"]),
                Models.Node(id: "X", agent: .literal("fake"), prompt: "x"),
                Models.Node(id: "Y", agent: .literal("fake"), prompt: "y", dependsOn: ["X"]),
            ]
        )

        let plan = try planner.plan(workflow: workflow)

        #expect(plan.topologicalOrder.count == 4)
        // A before B, X before Y.
        let indexA = plan.topologicalOrder.firstIndex(of: "A")!
        let indexB = plan.topologicalOrder.firstIndex(of: "B")!
        let indexX = plan.topologicalOrder.firstIndex(of: "X")!
        let indexY = plan.topologicalOrder.firstIndex(of: "Y")!

        #expect(indexA < indexB)
        #expect(indexX < indexY)
    }

    // MARK: - Dependents Map

    @Test("Dependents map is correctly built")
    func dependentsMap() throws {
        let workflow = Workflow(
            name: "deps",
            nodes: [
                Models.Node(id: "A", agent: .literal("fake"), prompt: "a"),
                Models.Node(id: "B", agent: .literal("fake"), prompt: "b", dependsOn: ["A"]),
                Models.Node(id: "C", agent: .literal("fake"), prompt: "c", dependsOn: ["A"]),
            ]
        )

        let plan = try planner.plan(workflow: workflow)

        let dependentsOfA = Set(plan.dependents["A"] ?? [])
        #expect(dependentsOfA == Set(["B", "C"]))
        #expect(plan.dependents["B"] == nil || plan.dependents["B"]!.isEmpty)
    }

    // MARK: - Single Node

    @Test("Single node workflow plans correctly")
    func singleNode() throws {
        let workflow = Workflow(
            name: "single",
            nodes: [
                Models.Node(id: "only", agent: .literal("fake"), prompt: "solo")
            ]
        )

        let plan = try planner.plan(workflow: workflow)

        #expect(plan.topologicalOrder == ["only"])
        #expect(plan.nodesByID["only"]?.id == "only")
    }
}
