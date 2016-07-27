type memLDA <: TopicModel
	K::Int
	M::Int
	V::Int
	N::Vector{Int}
	C::Vector{Int}
	corp::Corpus
	topics::VectorList{Int}
	alpha::Vector{Float64}
	beta::Matrix{Float64}
	betamem::Matrix{Float64}
	gamma::Vector{Float64}
	phi::Matrix{Float64}
	Elogtheta::VectorList{Float64}
	elbo::Float64
	elbomem::Float64

	function memLDA(corp::Corpus, K::Integer)
		@assert ispositive(K)
		@assert !isempty(corp)
		checkcorp(corp)

		M, V, U = size(corp)
		N = [length(doc) for doc in corp]
		C = [size(doc) for doc in corp]
		
		topics = [collect(1:V) for _ in 1:K]

		alpha = ones(K)
		beta = rand(Dirichlet(V, 1.0), K)'
		betamem = zeros(K, V)
		gamma = ones(K)
		phi = ones(K, N[1]) / K
		Elogtheta = fill(digamma(ones(K)) - digamma(K), M)
	
		model = new(K, M, V, N, C, copy(corp), topics, alpha, beta, betamem, gamma, phi, Elogtheta, 0, 0)
		for d in 1:M
			model.phi = ones(K, N[d]) / K
			updateELBOMEM!(model, d)
		end
		model.phi = ones(K, N[1]) / K
		updateELBO!(model)
		return model
	end
end

function Elogptheta(model::memLDA, d::Int)
	x = lgamma(sum(model.alpha)) - sum(lgamma(model.alpha)) + dot(model.alpha - 1, model.Elogtheta[d])
	return x
end

function Elogpz(model::memLDA, d::Int)
	counts = model.corp[d].counts
	x = dot(model.phi * counts, model.Elogtheta[d])
	return x
end

function Elogpw(model::memLDA, d::Int)
	terms, counts = model.corp[d].terms, model.corp[d].counts
	x = sum(model.phi .* log(model.beta[:,terms] + epsln) * counts)
	return x
end

function Elogqtheta(model::memLDA)
	x = -entropy(Dirichlet(model.gamma))
	return x
end

function Elogqz(model::memLDA, d::Int)
	counts = model.corp[d].counts
	x = -sum([c * entropy(Categorical(model.phi[:,n])) for (n, c) in enumerate(counts)])
	return x
end

function updateELBO!(model::memLDA)
	model.elbo = model.elbomem
	model.elbomem = 0
	return model.elbo
end

function updateELBOMEM!(model::memLDA, d::Int)
	model.elbomem += (Elogptheta(model, d)
					+ Elogpz(model, d)
					+ Elogpw(model, d) 
					- Elogqtheta(model)
					- Elogqz(model, d))
end

function updateAlpha!(model::memLDA, niter::Integer, ntol::Real)
	"Interior-point Newton method with log-barrier and back-tracking line search."

	nu = model.K
	for _ in 1:niter
		rho = 1.0
		alphaGrad = [(nu / model.alpha[i]) + model.M * (digamma(sum(model.alpha)) - digamma(model.alpha[i])) for i in 1:model.K] + sum(model.Elogtheta)
		alphaHessDiag = -(model.M * trigamma(model.alpha) + (nu ./ model.alpha.^2))
		p = (alphaGrad - sum(alphaGrad ./ alphaHessDiag) / (1 / (model.M * trigamma(sum(model.alpha))) + sum(1 ./ alphaHessDiag))) ./ alphaHessDiag
		
		while minimum(model.alpha - rho * p) < 0
			rho *= 0.5
		end	
		model.alpha -= rho * p
		
		if (norm(alphaGrad) < ntol) & ((nu / model.K) < ntol)
			break
		end
		nu *= 0.5
	end
	@bumper model.alpha
end

function updateBeta!(model::memLDA)	
	model.beta = model.betamem ./ sum(model.betamem, 2)
	model.betamem = zeros(model.K, model.V)
end

function updateBetaMEM!(model::memLDA, d::Int)	
	terms, counts = model.corp[d].terms, model.corp[d].counts
	model.betamem[:,terms] += model.phi .* counts'		
end

function updateGamma!(model::memLDA, d::Int)
	counts = model.corp[d].counts
	@bumper model.gamma = model.alpha + model.phi * counts	
end

function updatePhi!(model::memLDA, d::Int)
	terms = model.corp[d].terms
	model.phi = model.beta[:,terms] .* exp(model.Elogtheta[d])
	model.phi ./= sum(model.phi, 1)
end

function updateElogtheta!(model::memLDA, d::Int)
	model.Elogtheta[d] = digamma(model.gamma) - digamma(sum(model.gamma))
end

function train!(model::memLDA; iter::Integer=150, tol::Real=1.0, niter::Integer=1000, ntol::Real=1/model.K^2, viter::Integer=10, vtol::Real=1/model.K^2, chkelbo::Integer=1)
	@assert all(!isnegative([tol, ntol, vtol]))
	@assert all(ispositive([iter, niter, viter, chkelbo]))
	fixmodel!(model)	

	for k in 1:iter
		chk = (k % chkelbo == 0)
		for d in 1:model.M	
			for _ in 1:viter
				oldgamma = copy(model.gamma)
				updatePhi!(model, d)
				updateGamma!(model, d)
				updateElogtheta!(model, d)
				if norm(oldgamma - model.gamma) < vtol
					break
				end
			end
			chk && updateELBOMEM!(model, d)
			updateBetaMEM!(model, d)
		end
		updateAlpha!(model, niter, ntol)		
		updateBeta!(model)
		if checkELBO!(model, k, chkelbo, tol)
			break
		end
	end
	model.gamma = ones(model.K)
	model.phi = ones(model.K, model.N[1]) / model.K
	model.topics = [reverse(sortperm(vec(model.beta[i,:]))) for i in 1:model.K]
	nothing
end



