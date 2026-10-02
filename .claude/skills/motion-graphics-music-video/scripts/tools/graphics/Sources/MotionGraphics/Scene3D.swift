import Foundation
import SceneKit
import Metal
import CoreImage

/// Native SceneKit geometry/material/camera interoperability; rendered into a retained Metal texture.
/// SceneKit is deprecated in newer SDKs; isolated here so a future Metal/RealityKit backend can replace it.
public final class Scene3D {
    public enum Primitive { case box, sphere, plane, cone, cylinder, torus, ellipsoid }
    public let scene = SCNScene(), camera = SCNNode()
    private var prepared = false
    private let renderer: SCNRenderer, queue: MTLCommandQueue, texture: MTLTexture, depth: MTLTexture
    public init(width: Int, height: Int, device: MTLDevice? = MTLCreateSystemDefaultDevice()) throws {
        guard width > 0, height > 0, let device, let queue = device.makeCommandQueue() else { throw GraphicsError.unavailable("3D rendering requires Metal and positive dimensions") }
        self.queue = queue; renderer = SCNRenderer(device:device,options:nil)
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba16Float,width:width,height:height,mipmapped:false)
        desc.usage = [.renderTarget,.shaderRead]; desc.storageMode = .private
        guard let color = device.makeTexture(descriptor:desc) else { throw GraphicsError.unavailable("3D surface allocation failed") }; texture = color
        desc.pixelFormat = .depth32Float; desc.usage = .renderTarget
        guard let z = device.makeTexture(descriptor:desc) else { throw GraphicsError.unavailable("3D depth allocation failed") }; depth = z
        camera.camera = SCNCamera(); camera.camera!.zNear = 0.1; camera.camera!.zFar = 100; camera.position = SCNVector3(0,0,6); scene.rootNode.addChildNode(camera)
        renderer.scene = scene; renderer.pointOfView = camera; renderer.autoenablesDefaultLighting = true
        scene.background.contents = CGColor(red:0,green:0,blue:0,alpha:0)
    }
    @discardableResult public func add(_ primitive: Primitive, color: Color = .white, wireframe: Bool = false) -> SCNNode {
        let geometry: SCNGeometry
        switch primitive {
        case .box: geometry = SCNBox(width:1,height:1,length:1,chamferRadius:0)
        case .sphere, .ellipsoid: geometry = SCNSphere(radius:0.6)
        case .plane: geometry = SCNPlane(width:1,height:1)
        case .cone: geometry = SCNCone(topRadius:0,bottomRadius:0.5,height:1)
        case .cylinder: geometry = SCNCylinder(radius:0.5,height:1)
        case .torus: geometry = SCNTorus(ringRadius:0.65,pipeRadius:0.2)
        }
        let material = SCNMaterial(); material.diffuse.contents = color.cgColor; material.lightingModel = .physicallyBased
        material.fillMode = wireframe ? .lines : .fill; geometry.materials = [material]
        let node = SCNNode(geometry:geometry); if primitive == .ellipsoid { node.scale = SCNVector3(1,0.6,1.4) }
        scene.rootNode.addChildNode(node); prepared = false; return node
    }
    @discardableResult public func loadModel(_ url: URL) throws -> SCNNode {
        let loaded = try SCNScene(url:url,options:nil), group = SCNNode()
        for child in loaded.rootNode.childNodes { group.addChildNode(child) }
        scene.rootNode.addChildNode(group); prepared = false; return group
    }
    public func render(at time: Double) throws -> CIImage {
        SCNTransaction.flush()
        if !prepared { guard renderer.prepare(scene, shouldAbortBlock:nil) else { throw GraphicsError.unavailable("3D scene preparation failed") }; prepared = true }
        renderer.sceneTime = time
        guard let command = queue.makeCommandBuffer() else { throw GraphicsError.unavailable("3D command allocation failed") }
        let pass = MTLRenderPassDescriptor(); pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0,0,0,0)
        pass.depthAttachment.texture = depth; pass.depthAttachment.loadAction = .clear; pass.depthAttachment.storeAction = .dontCare; pass.depthAttachment.clearDepth = 1
        renderer.render(atTime:time,viewport:CGRect(x:0,y:0,width:texture.width,height:texture.height),commandBuffer:command,passDescriptor:pass)
        command.commit(); command.waitUntilCompleted(); if let error = command.error { throw error }
        guard let image = CIImage(mtlTexture:texture,options:[.colorSpace:Color.space]) else { throw GraphicsError.io("Cannot wrap 3D texture") }
        return image.transformed(by:CGAffineTransform(a:1,b:0,c:0,d:-1,tx:0,ty:CGFloat(texture.height)))
    }
}
