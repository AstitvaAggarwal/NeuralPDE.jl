pages = ["index.md",
    "ODE PINN Tutorials" => Any["Introduction to NeuralPDE for ODEs" => "tutorials/ode.md",
                                "Bayesian PINNs for Coupled ODEs" => "tutorials/Lotka_Volterra_BPINNs.md",
                                "PINNs DAEs" => "tutorials/dae.md",
                                "Parameter Estimation with PINNs for ODEs" => "tutorials/ode_parameter_estimation.md",
                                "Deep Galerkin Method" => "tutorials/dgm.md"
                                #"examples/nnrode_example.md", # currently incorrect
                                ],
    "PDE PINN Tutorials" => Any["Introduction to NeuralPDE for PDEs" => "tutorials/pdesystem.md",
                                "Bayesian PINNs for PDEs" => "tutorials/low_level_2.md",
                                "Using GPUs" => "tutorials/gpu.md",
                                "Defining Systems of PDEs" => "tutorials/systems.md",
                                "Imposing Constraints" => "tutorials/constraints.md",
                                "The symbolic_discretize Interface" => "tutorials/low_level.md",
                                "Optimising Parameters (Solving Inverse Problems)" => "tutorials/param_estim.md",
                                "Solving Integro Differential Equations" => "tutorials/integro_diff.md",
                                "Transfer Learning with Neural Adapter" => "tutorials/neural_adapter.md",
                                "The Derivative Neural Network Approximation" => "tutorials/derivative_neural_network.md"],
    "Extended Examples" => Any["examples/wave.md",
                               "examples/3rd.md",
                               "examples/ks.md",
                               "examples/heterogeneous.md",
                               "examples/linear_parabolic.md",
                               "examples/nonlinear_elliptic.md",
                               "examples/nonlinear_hyperbolic.md"],
    "Manual" => Any["manual/ode.md",
                    "manual/dae.md",
                    "manual/pinns.md",
                    "manual/bpinns.md",
                    "manual/training_strategies.md",
                    "manual/adaptive_losses.md",
                    "manual/logging.md",
                    "manual/neural_adapters.md"],
    "Developer Documentation" => Any["developer/debugging.md"],
]
